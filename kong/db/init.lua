local DAO          = require "kong.db.dao"
local Entity       = require "kong.db.schema.entity"
local Errors       = require "kong.db.errors"
local Strategies   = require "kong.db.strategies"
local MetaSchema   = require "kong.db.schema.metaschema"


local fmt          = string.format
local type         = type
local pairs        = pairs
local error        = error
local ipairs       = ipairs
local rawget       = rawget
local setmetatable = setmetatable


-- maybe a temporary constant table -- could be move closer
-- to schemas and entities since schemas will also be used
-- independently from the DB module (Admin API for GUI)
-- Notice that the order in which they are listed is important:
-- schemas of dependencies need to be loaded first.
local CORE_ENTITIES = {
  "consumers",
  "services",
  "routes",
  "certificates",
  "snis",
  "upstreams",
  "targets",
  "apis",
  "plugins",
}


local DEFAULT_LOCKS_TTL = 60 -- seconds


local DB = {}
DB.__index = function(self, k)
  return DB[k] or rawget(self, "daos")[k]
end


function DB.new(kong_config, strategy)
  if not kong_config then
    error("missing kong_config", 2)
  end

  if strategy ~= nil and type(strategy) ~= "string" then
    error("strategy must be a string", 2)
  end

  strategy = strategy or kong_config.database

  -- load errors

  local errors = Errors.new(strategy)

  local schemas = {}

  do
    -- load schemas
    -- core entities are for now the only source of schemas.
    -- TODO: support schemas from plugins entities as well.

    for _, entity_name in ipairs(CORE_ENTITIES) do
      local entity_schema = require("kong.db.schema.entities." .. entity_name)

      -- validate core entities schema via metaschema
      local ok, err_t = MetaSchema:validate(entity_schema)
      if not ok then
        return nil, fmt("schema of entity '%s' is invalid: %s", entity_name,
                        tostring(errors:schema_violation(err_t)))
      end
      local entity, err = Entity.new(entity_schema)
      if not entity then
        return nil, fmt("schema of entity '%s' is invalid: %s", entity_name,
                        err)
      end
      schemas[entity_name] = entity
    end
  end

  -- load strategy

  local connector, strategies, err = Strategies.new(kong_config, strategy,
                                                    schemas, errors)
  if err then
    return nil, err
  end

  local daos = {}

  local self   = {
    daos       = daos,       -- each of those has the connector singleton
    strategies = strategies,
    connector  = connector,
    strategy   = strategy,
    errors     = errors,
    infos      = connector:infos(),
    kong_config = kong_config,
  }

  do
    -- load DAOs

    for _, schema in pairs(schemas) do
      local strategy = strategies[schema.name]
      if not strategy then
        return nil, fmt("no strategy found for schema '%s'", schema.name)
      end
      daos[schema.name] = DAO.new(self, schema, strategy, errors)
    end
  end

  -- we are 200 OK


  return setmetatable(self, DB)
end


local function prefix_err(self, err)
  return "[" .. self.infos.strategy .. " error] " .. err
end


local function fmt_err(self, err, ...)
  return prefix_err(self, fmt(err, ...))
end


function DB:init_connector()
  -- I/O with the DB connector singleton
  -- Implementation up to the strategy's connector. A place for:
  --   - connection check
  --   - cluster retrievel (cassandra)
  --   - prepare statements
  --   - nop (default)

  local ok, err = self.connector:init()
  if not ok then
    return nil, prefix_err(self, err)
  end

  self.infos = self.connector:infos()

  return ok
end


function DB:init_worker()
  -- Can be used to implement e.g. a timer jobs to
  -- clean expired records from database in case the
  -- database doesn't natively support TTL, such as
  -- PostgreSQL
  local ok, err = self.connector:init_worker(self.strategies)
  if not ok then
    return nil, prefix_err(self, err)
  end

  return ok
end


function DB:connect()
  local ok, err = self.connector:connect()
  if not ok then
    return nil, prefix_err(self, err)
  end

  return ok
end


function DB:setkeepalive()
  local ok, err = self.connector:setkeepalive()
  if not ok then
    return nil, prefix_err(self, err)
  end

  return ok
end


function DB:reset()
  local ok, err = self.connector:reset()
  if not ok then
    return nil, prefix_err(self, err)
  end

  return ok
end


function DB:truncate(table_name)
  if table_name ~= nil and type(table_name) ~= "string" then
    error("table_name must be a string", 2)
  end
  local ok, err

  if table_name then
    ok, err = self.connector:truncate_table(table_name)
  else
    ok, err = self.connector:truncate()
  end

  if not ok then
    return nil, prefix_err(self, err)
  end

  return ok
end


function DB:set_events_handler(events)
  for _, dao in pairs(self.daos) do
    dao.events = events
  end
end


do
  local public = require "kong.tools.public"
  local resty_lock = require "resty.lock"


  local MAX_LOCK_WAIT_STEP = 2 -- seconds


  local function release_rlock_and_ret(self, rlock, ...)
    rlock:unlock()

    local args = { ... }

    if type(args[2]) == "string" then
      args[2] = prefix_err(self, args[2])
    end

    return unpack(args)
  end


  function DB:cluster_mutex(key, opts, cb)
    if type(key) ~= "string" then
      error("key must be a string", 2)
    end

    local owner
    local ttl
    local no_wait
    local no_cleanup

    if opts ~= nil then
      if type(opts) ~= "table" then
        error("opts must be a table", 2)
      end

      if opts.ttl and type(opts.ttl) ~= "number" then
        error("opts.ttl must be a number", 2)
      end

      if opts.owner and type(opts.owner) ~= "string" then
        error("opts.owner must be a string", 2)
      end

      if opts.no_wait and type(opts.no_wait) ~= "boolean" then
        error("opts.no_wait must be a boolean", 2)
      end

      if opts.no_cleanup and type(opts.no_cleanup) ~= "boolean" then
        error("opts.no_cleanup must be a boolean", 2)
      end

      owner = opts.owner
      ttl = opts.ttl
      no_wait = opts.no_wait
      no_cleanup = opts.no_cleanup
    end

    if type(cb) ~= "function" then
      local mt = getmetatable(cb)

      if not mt or type(mt.__call) ~= "function" then
        error("cb must be a function", 2)
      end
    end

    if not owner then
      -- generate a random string for this worker (resty-cli or runtime nginx
      -- worker)
      -- we use the `get_node_id()` public utility, but in the CLI context,
      -- this value is ephemeral, so no assumptions should be made about the
      -- real owner of a lock
      local id, err = public.get_node_id()
      if not id then
        return nil, prefix_err(self, "failed to generate lock owner: " .. err)
      end

      owner = id
    end

    if not ttl then
      ttl = DEFAULT_LOCKS_TTL
    end

    local rlock, err = resty_lock:new("kong_locks", {
      exptime = ttl,
      timeout = ttl,
    })
    if not rlock then
      return nil, prefix_err(self, "failed to create worker lock: " .. err)
    end

    -- acquire a single worker

    local elapsed, err = rlock:lock(key)
    if not elapsed then
      if err == "timeout" then
        return nil, prefix_err(self, err)
      end

      return nil, prefix_err(self, "failed to acquire worker lock: " .. err)
    end

    if elapsed ~= 0 then
      -- we did not acquire the worker lock, but it was released
      return false
    end

    -- worker lock acquired, other workers are waiting on it
    -- now acquire cluster lock via strategy-specific connector

    local ok, err = self.connector:insert_lock(key, ttl, owner)
    if err then
      return release_rlock_and_ret(self, rlock, nil,
                                   "failed to insert cluster lock: " .. err)
    end

    if not ok then
      if no_wait then
        -- don't wait on cluster locked
        return release_rlock_and_ret(self, rlock, false)
      end

      -- waiting on cluster lock
      local step = 0.1
      local cluster_elapsed = 0

      while cluster_elapsed < ttl do
        ngx.sleep(step)
        cluster_elapsed = cluster_elapsed + step

        if cluster_elapsed >= ttl then
          break
        end

        local locked, err = self.connector:read_lock(key)
        if err then
          return release_rlock_and_ret(self, rlock, nil,
                                       "failed to read cluster lock: " .. err)
        end

        if not locked then
          -- the cluster lock was released
          return release_rlock_and_ret(self, rlock, false)
        end

        step = math.min(step * 3, MAX_LOCK_WAIT_STEP)
      end

      return release_rlock_and_ret(self, rlock, nil, "timeout")
    end

    -- cluster lock acquired, run callback

    local pok, perr = xpcall(cb, debug.traceback)
    if not pok then
      self.connector:remove_lock(key, owner)

      return release_rlock_and_ret(self, rlock, nil,
                                   "cluster_mutex callback threw an error: "
                                   .. perr)
    end

    if not no_cleanup then
      self.connector:remove_lock(key, owner)
    end

    return release_rlock_and_ret(self, rlock, true)
  end
end


do
  -- migrations
  local utils = require "kong.tools.utils"
  local log = require "kong.cmd.utils.log"
  local Schema = require "kong.db.schema"
  local Migration = require "kong.db.schema.others.migrations"
  local MigrationHelpers = require "kong.db.migrations.helpers"

  local pl_path = require "pl.path"
  local pl_dir = require "pl.dir"


  local MigrationSchema = Schema.new(Migration)


  local schema_migrations_mt = {
    __tostring = function(t)
      local subsystems = {}

      for _, subsys in ipairs(t) do
        local names = {}

        for _, migration in ipairs(subsys.migrations) do
          table.insert(names, migration.name)
        end

        table.insert(subsystems, fmt("%s: %s", subsys.subsystem,
                                               table.concat(names, ", ")))
      end

      return table.concat(subsystems, "\n")
    end,
  }


  local function load_subsystems(self, plugin_names)
    if type(plugin_names) ~= "table" then
      error("plugin_names must be a table", 2)
    end

    local namespace = "kong.db.migrations"
    local core_namespace = fmt("%s.core", namespace)

    local res = {
      {
        name = "core",
        namespace = core_namespace,
        migrations_index = require(core_namespace),
      },
    }

    -- load core subsystems

    local core_path = pl_path.package_path(core_namespace)

    local dir_path, n = string.gsub(pl_path.abspath(core_path),
                                    "core" .. pl_path.sep .. "init%.lua$", "")
    if n ~= 1 then
      return nil, prefix_err(self, "failed to substitute migrations path in "
                             .. dir_path)
    end

    local dirs = pl_dir.getdirectories(dir_path)

    for _, dir in ipairs(dirs) do
      if not string.find(dir, "core$") then
        local name = pl_path.basename(dir)
        local namespace = fmt("%s.%s", namespace, name)
        local filepath = dir .. pl_path.sep .. "init.lua"
        local index = assert(loadfile(filepath))

        local mig_idx = index()
        if type(mig_idx) ~= "table" then
          return nil, fmt_err(self, "migrations index at '%s' must be a table",
                              filepath)
        end

        table.insert(res, {
          name = name,
          namespace = namespace,
          migrations_index = mig_idx,
        })
      end
    end

    -- load plugins

    for plugin_name in pairs(plugin_names) do
      local namespace = "kong.plugins." .. plugin_name .. ".migrations"

      local ok, mig_idx = utils.load_module_if_exists(namespace)
      if ok then
        if type(mig_idx) ~= "table" then
          return nil, fmt_err(self, "migrations index from '%s' must be a table",
                              namespace)
        end

        table.insert(res, {
          name = plugin_name,
          namespace = namespace,
          migrations_index = mig_idx,
        })
      end
    end

    for _, subsys in ipairs(res) do
      subsys.migrations = {}

      for _, mig_name in ipairs(subsys.migrations_index) do
        local mig_module = fmt("%s.%s", subsys.namespace, mig_name)

        local ok, migration = utils.load_module_if_exists(mig_module)
        if not ok then
          return nil, fmt_err(self, "failed to load migration '%s' of '%s' subsystem",
                              mig_module, subsys.name)
        end

        migration.name = mig_name

        local ok, errors = MigrationSchema:validate(migration)
        if not ok then
          local err_t = Errors:schema_violation(errors)
          return nil, fmt_err(self, "migration '%s' of '%s' subsystem is invalid: %s",
                              mig_module, subsys.name, tostring(err_t))
        end

        table.insert(subsys.migrations, migration)
      end
    end

    return res
  end


  function DB:schema_state()
    log.debug("loading subsystems migrations...")

    local subsystems, err = load_subsystems(self, self.kong_config.loaded_plugins)
    if not subsystems then
      return nil, prefix_err(self, err)
    end

    log.verbose("retrieving %s schema state...", self.infos.db_desc)

    local ok, err = self.connector:connect_migrations({ no_keyspace = true })
    if not ok then
      return nil, prefix_err(self, err)
    end

    local rows, err = self.connector:schema_migrations()

    self.connector:close()

    if err then
      return nil, prefix_err(self, "failed to check schema state: " .. err)
    end

    log.verbose("schema state retrieved")

    local schema_state = {
      needs_bootstrap = false,
      executed_migrations = nil,
      pending_migrations = nil,
      missing_migrations = nil,
      new_migrations = nil,
    }

    local rows_as_hash = {}

    if not rows then
      schema_state.needs_bootstrap = true

    else
      for _, row in ipairs(rows) do
        rows_as_hash[row.subsystem] = {
          last_executed = row.last_executed,
          executed = row.executed or {},
          pending = row.pending or {},
        }
      end
    end

    for _, subsystem in ipairs(subsystems) do
      local subsystem_state = {
        executed_migrations = {},
        pending_migrations = {},
        missing_migrations = {},
        new_migrations = {},
      }

      if not rows_as_hash[subsystem.name] then
        -- no migrations for this subsystem in DB, all migrations are 'new' (to
        -- run)
        for i, mig in ipairs(subsystem.migrations) do
          subsystem_state.new_migrations[i] = mig
        end

      else
        -- some migrations have previously ran for this subsystem

        local n

        for i, mig in ipairs(subsystem.migrations) do
          if mig.name == rows_as_hash[subsystem.name].last_executed then
            n = i + 1
          end

          local found

          for _, db_mig in ipairs(rows_as_hash[subsystem.name].executed) do
            if mig.name == db_mig then
              found = true
              table.insert(subsystem_state.executed_migrations, mig)
              break
            end
          end

          if not found then
            for _, db_mig in ipairs(rows_as_hash[subsystem.name].pending) do
              if mig.name == db_mig then
                found = true
                table.insert(subsystem_state.pending_migrations, mig)
                break
              end
            end
          end

          if not found then
            if not n or i >= n then
              table.insert(subsystem_state.new_migrations, mig)

            else
              table.insert(subsystem_state.missing_migrations, mig)
            end
          end
        end
      end

      for k, v in pairs(subsystem_state) do
        if #v > 0 then
          if not schema_state[k] then
            schema_state[k] = setmetatable({}, schema_migrations_mt)
          end

          table.insert(schema_state[k], {
            subsystem = subsystem.name,
            namespace = subsystem.namespace,
            migrations = v,
          })
        end
      end
    end

    return schema_state
  end


  function DB:is_schema_up_to_date(schema_state)
    if type(schema_state) ~= "table" then
      error("schema_state must be a table", 2)
    end

    return not schema_state.needs_bootstrap and not schema_state.new_migrations
  end


  function DB:schema_bootstrap()
    local ok, err = self.connector:connect_migrations({ no_keyspace = true })
    if not ok then
      return nil, prefix_err(self, err)
    end

    local ok, err = self.connector:schema_bootstrap(self.kong_config,
                                                    DEFAULT_LOCKS_TTL)

    self.connector:close()

    if not ok then
      return nil, prefix_err(self, "failed to bootstrap database: " .. err)
    end

    return true
  end


  function DB:schema_reset()
    local ok, err = self.connector:connect_migrations({ no_keyspace = true })
    if not ok then
      return nil, prefix_err(self, err)
    end

    local ok, err = self.connector:schema_reset()

    self.connector:close()

    if not ok then
      return nil, prefix_err(self, err)
    end

    return true
  end


  function DB:run_migrations(migrations, options)
    if type(migrations) ~= "table" then
      error("migrations must be a table", 2)
    end

    if type(options) ~= "table" then
      error("options must be a table", 2)
    end

    local run_up = options.run_up
    local run_teardown = options.run_teardown

    if not run_up and not run_teardown then
      error("options.run_up or options.run_teardown must be given", 2)
    end

    local ok, err = self.connector:connect_migrations()
    if not ok then
      return nil, prefix_err(self, err)
    end

    local mig_helpers = MigrationHelpers.new(self.connector)

    local n_migrations = 0
    local n_pending = 0

    for _, t in ipairs(migrations) do
      log("migrating %s on %s '%s'...", t.subsystem, self.infos.db_desc,
          self.infos.db_name)

      for _, mig in ipairs(t.migrations) do
        local ok, mod = utils.load_module_if_exists(t.namespace .. "." ..
                                                    mig.name)
        if not ok then
          return nil, fmt_err(self, "failed to load migration '%s': %s",
                              mig.name, mod)
        end

        local strategy_migration = mod[self.strategy]
        if not strategy_migration then
          return nil, fmt_err(self, "missing %s strategy for migration '%s'",
                              self.strategy, mig.name)
        end

        if t.subsystem == "core" and mig.name == "000_base" then
          local res, err = self.connector:is_014()
          if err then
            return nil, fmt_err(self, "unable to detect database version (%s)",
                                err)
          end

          if not res.is_eq_014 and not res.is_gt_014 then
            if res.missing_migration then
              return nil, fmt_err(self,
                                  "Migration to 1.0 can only be performed "  ..
                                  "from a 0.14.x %s %s, but the current "    ..
                                  "one seems to be older (missing "          ..
                                  "migration '%s' for '%s'). Migrate to "    ..
                                  "0.14.x first, or install 1.0 on "         ..
                                  "a fresh %s.",
                                  self.strategy, self.infos.db_desc,
                                  res.missing_migration, res.missing_component,
                                  self.infos.db_desc)
            end

            if res.missing_component then
              return nil, fmt_err(self,
                                  "Migration to 1.0 can only be performed "  ..
                                  "from a 0.14.x %s %s, but the current "    ..
                                  "one seems to be older (missing "          ..
                                  "migrations for '%s'). Migrate to 0.14.x " ..
                                  "first, or install 1.0 on a fresh %s.",
                                  self.strategy, self.infos.db_desc,
                                  res.missing_component, self.infos.db_desc)
            end

            return nil, fmt_err(self,
                                "Migration to 1.0 can only be performed "    ..
                                "from a 0.14.x %s %s, but the current one "  ..
                                "seems to be older (missing migrations)."    ..
                                "Migrate to 0.14.x first, or install 1.0 "   ..
                                "on a fresh %s.", self.strategy,
                                self.infos.db_desc, self.infos.db_desc)
          end
        end

        log.debug("running migration: %s", mig.name)

        if run_up then
          -- kong migrations bootstrap
          -- kong migrations up
          ok, err = self.connector:run_up_migration(mig.name,
                                                    strategy_migration.up)
          if not ok then
            self.connector:close()
            return nil, fmt_err(self, "failed to run migration '%s' up: %s",
                                mig.name, err)
          end

          local state = "executed"
          if strategy_migration.teardown then
            -- this migration has a teardown step for later
            state = "pending"
            n_pending = n_pending + 1
          end

          ok, err = self.connector:record_migration(t.subsystem, mig.name,
                                                    state)
          if not ok then
            self.connector:close()
            return nil, fmt_err(self, "failed to record migration '%s': %s",
                                mig.name, err)
          end
        end

        if run_teardown and strategy_migration.teardown then
          -- kong migrations teardown
          local f = strategy_migration.teardown

          local pok, perr, err = xpcall(f, debug.traceback, self.connector,
                                        mig_helpers)
          if not pok or err then
            self.connector:close()
            return nil, fmt_err(self, "failed to run migration '%s' teardown: %s",
                                mig.name, perr or err)
          end

          ok, err = self.connector:record_migration(t.subsystem, mig.name,
                                                    "teardown")
          if not ok then
            self.connector:close()
            return nil, fmt_err(self, "failed to record migration '%s': %s",
                                mig.name, err)
          end

          n_pending = math.max(n_pending - 1, 0)
        end

        log("%s migrated up to: %s %s", t.subsystem, mig.name,
            strategy_migration.teardown
            and not run_teardown and "(pending)" or "(executed)")

        n_migrations = n_migrations + 1
      end
    end

    log("%d migration%s processed", n_migrations,
        n_migrations > 1 and "s" or "")

    local n_executed = n_migrations - n_pending

    if n_executed > 0 then
      log("%d executed", n_executed)
    end

    if n_pending > 0 then
      log("%d pending", n_pending)
    end

    if run_up then
      ok, err = self.connector:post_run_up_migrations()
      if not ok then
        return nil, prefix_err(self, err)
      end
    end

    self.connector:close()

    return true
  end


  --[[
  function DB:load_pending_migrations(migrations)
    if type(migrations) ~= "table" then
      error("migrations must be a table", 2)
    end

    for _, t in ipairs(migrations) do
      for _, mig in ipairs(t.migrations) do
        local ok, mod = utils.load_module_if_exists(t.namespace .. "." ..
                                                    mig.name)
        if not ok then
          return nil, fmt("failed to load migration '%s': %s", mig.name,
                          mod)
        end

        if mod.translations then
          ngx.log(ngx.INFO, "loading translation functions for migration ",
                            "'", mig.name, "'")

          for _, translation in ipairs(mod.translations) do
            local dao = self.daos[translation.entity]
            if not dao then
              return nil, fmt("failed to load translation function for " ..
                              "migration '%s': no '%s' DAO exists", mig.name,
                              translation.entity)
            end

            dao:load_translations(mod.translations)
          end
        end
      end
    end

    self.connector:close()

    return true
  end
  --]]
end


return DB
