local log = require "kong.cmd.utils.log"
local cassandra = require "cassandra"
local utils = require "kong.tools.utils"
local cjson = require "cjson"

local migration_helpers = require "kong.dao.migrations.helpers"

return {
  {
    name = "2015-01-12-175310_skeleton",
    up = function(db, kong_config)
      local keyspace_name = kong_config.cassandra_keyspace
      local strategy, strategy_properties = kong_config.cassandra_repl_strategy, ""

      -- Format strategy options
      if strategy == "SimpleStrategy" then
        strategy_properties = string.format(", 'replication_factor': %s", kong_config.cassandra_repl_factor)
      elseif strategy == "NetworkTopologyStrategy" then
        local dcs = {}
        for _, dc_conf in ipairs(kong_config.cassandra_data_centers) do
          local dc_name, dc_repl = string.match(dc_conf, "([^:]+):(%d+)")
          if dc_name and dc_repl then
            table.insert(dcs, string.format("'%s': %s", dc_name, dc_repl))
          else
            return "invalid cassandra_data_centers configuration"
          end
        end
        if #dcs > 0 then
          strategy_properties = string.format(", %s", table.concat(dcs, ", "))
        end
      else
        -- Strategy unknown
        return "invalid replication_strategy class"
      end

      -- Test keyspace existence by trying to switch to it. The keyspace
      -- could have been created by a DBA or could not exist.
      local ok, err = db:coordinator_change_keyspace(keyspace_name)
      if not ok then
        -- The keyspace either does not exist or we do not have access
        -- to it. Let's try to create it.
        log("could not switch to %s keyspace (%s), attempting to create it",
            keyspace_name, err)

        local keyspace_str = string.format([[
          CREATE KEYSPACE IF NOT EXISTS "%s"
            WITH REPLICATION = {'class': '%s'%s};
        ]], keyspace_name, strategy, strategy_properties)

        local res, err = db:query(keyspace_str, nil, nil, nil, true)
        if not res then
          -- keyspace creation failed (no sufficients permissions or
          -- any other reason)
          return err
        end

        log("successfully created %s keyspace", keyspace_name)

        local ok, err = db:coordinator_change_keyspace(keyspace_name)
        if not ok then
          return err
        end
      end

      local res, err = db:query [[
        CREATE TABLE IF NOT EXISTS schema_migrations(
          id text PRIMARY KEY,
          migrations list<text>
        );
      ]]
      if not res then
        return err
      end
    end,
    down = [[
      DROP TABLE schema_migrations;
    ]]
  },
  {
    name = "2015-01-12-175310_init_schema",
    up = [[
      CREATE TABLE IF NOT EXISTS consumers(
        id uuid,
        custom_id text,
        username text,
        created_at timestamp,
        PRIMARY KEY (id)
      );

      CREATE INDEX IF NOT EXISTS ON consumers(custom_id);
      CREATE INDEX IF NOT EXISTS ON consumers(username);

      CREATE TABLE IF NOT EXISTS apis(
        id uuid,
        name text,
        request_host text,
        request_path text,
        strip_request_path boolean,
        upstream_url text,
        preserve_host boolean,
        created_at timestamp,
        PRIMARY KEY (id)
      );

      CREATE INDEX IF NOT EXISTS ON apis(name);
      CREATE INDEX IF NOT EXISTS ON apis(request_host);
      CREATE INDEX IF NOT EXISTS ON apis(request_path);

      CREATE TABLE IF NOT EXISTS plugins(
        id uuid,
        api_id uuid,
        consumer_id uuid,
        name text,
        config text, -- serialized plugin configuration
        enabled boolean,
        created_at timestamp,
        PRIMARY KEY (id, name)
      );

      CREATE INDEX IF NOT EXISTS ON plugins(name);
      CREATE INDEX IF NOT EXISTS ON plugins(api_id);
      CREATE INDEX IF NOT EXISTS ON plugins(consumer_id);
    ]],
    down = [[
      DROP TABLE consumers;
      DROP TABLE apis;
      DROP TABLE plugins;
    ]]
  },
  {
    name = "2015-11-23-817313_nodes",
    up = [[
      CREATE TABLE IF NOT EXISTS nodes(
        name text,
        cluster_listening_address text,
        created_at timestamp,
        PRIMARY KEY (name)
      ) WITH default_time_to_live = 3600;

      CREATE INDEX IF NOT EXISTS ON nodes(cluster_listening_address);
    ]],
    down = [[
      DROP TABLE nodes;
    ]]
  },
  {
    name = "2016-02-25-160900_remove_null_consumer_id",
    up = function(db, _, _)

      local coordinator = db:get_coordinator()
      for rows, err in coordinator:iterate([[
        SELECT *
        FROM plugins
        WHERE consumer_id = 00000000-0000-0000-0000-000000000000
      ]]) do
        if err then
          return err
        end

        for _, row in ipairs(rows) do
          local _
          _, err = db:query([[
            UPDATE plugins
            SET consumer_id = NULL
            WHERE id = ?]], { row.id })
          if err then
            return err
          end
        end
      end
    end
  },
  {
    name = "2016-02-29-121813_remove_ttls",
    up = [[
      ALTER TABLE nodes WITH default_time_to_live = 0;
    ]],
    down = [[
      ALTER TABLE nodes WITH default_time_to_live = 3600;
    ]]
  },
  {
    -- This is a 2 step migration; first create the extra column, using a cql
    -- statement and following iterate over the entries to insert default values.

    -- Step 1) create extra column
    name = "2016-09-05-212515_retries_step_1",
    up = [[
      ALTER TABLE apis ADD retries int;
    ]],
    down = [[
      ALTER TABLE apis DROP retries;
    ]]
  },
  {
    -- Step 2) insert default values
    name = "2016-09-05-212515_retries_step_2",
    up = function(_, _, dao)
      local rows, err = dao.apis:find_all() -- fetch all rows
      if err then
        return err
      end

      for _, row in ipairs(rows) do
        if not row.retries then

          local _, err = dao.apis:update({
            retries = 5
          }, {
            id = row.id
          })
          if err then
            return err
          end
        end
      end
    end,
    down = nil,
  },
  {
    name = "2016-09-16-141423_upstreams",
    -- Note on the timestamps;
    -- The Cassandra timestamps are created in Lua code, and hence ALL entities
    -- will now be created in millisecond precision. The existing entries will
    -- remain in second precision, but new ones (for ALL entities!) will be
    -- in millisecond precision.
    -- This differs from the Postgres one where only the new entities (upstreams
    -- and targets) will get millisecond precision.
    up = [[
      CREATE TABLE IF NOT EXISTS upstreams(
        id uuid,
        name text,
        slots int,
        orderlist text,
        created_at timestamp,
        PRIMARY KEY (id)
      );
      CREATE INDEX IF NOT EXISTS ON upstreams(name);
      CREATE TABLE IF NOT EXISTS targets(
        id uuid,
        target text,
        weight int,
        upstream_id uuid,
        created_at timestamp,
        PRIMARY KEY (id)
      );
      CREATE INDEX IF NOT EXISTS ON targets(upstream_id);
    ]],
    down = [[
      DROP TABLE upstreams;
      DROP TABLE targets;
    ]],
  },
  {
    name = "2016-12-14-172100_move_ssl_certs_to_core",
    up = [[
      CREATE TABLE IF NOT EXISTS ssl_certificates(
        id uuid PRIMARY KEY,
        cert text,
        key text ,
        created_at timestamp
      );

      CREATE TABLE IF NOT EXISTS ssl_servers_names(
        name text,
        ssl_certificate_id uuid,
        created_at timestamp,
        PRIMARY KEY (name, ssl_certificate_id)
      );

      CREATE INDEX IF NOT EXISTS ON ssl_servers_names(ssl_certificate_id);

      ALTER TABLE apis ADD https_only boolean;
      ALTER TABLE apis ADD http_if_terminated boolean;
    ]],
    down = [[
      DROP INDEX ssl_servers_names_ssl_certificate_idx;

      DROP TABLE ssl_certificates;
      DROP TABLE ssl_servers_names;

      ALTER TABLE apis DROP https_only;
      ALTER TABLE apis DROP http_if_terminated;
    ]]
  },
  {
    name = "2016-11-11-151900_new_apis_router_1",
    up = [[
      ALTER TABLE apis ADD hosts text;
      ALTER TABLE apis ADD uris text;
      ALTER TABLE apis ADD methods text;
      ALTER TABLE apis ADD strip_uri boolean;
    ]],
    down = [[
      ALTER TABLE apis DROP headers;
      ALTER TABLE apis DROP uris;
      ALTER TABLE apis DROP methods;
      ALTER TABLE apis DROP strip_uri;
    ]]
  },
  {
    name = "2016-11-11-151900_new_apis_router_2",
    up = function(_, _, dao)
      -- create request_headers and request_uris
      -- with one entry each: the current request_host
      -- and the current request_path
      local rows, err = dao.apis:find_all() -- fetch all rows
      if err then
        return err
      end

      for _, row in ipairs(rows) do
        local hosts
        local uris

        local upstream_url = row.upstream_url
        while string.sub(upstream_url, #upstream_url) == "/" do
          upstream_url = string.sub(upstream_url, 1, #upstream_url - 1)
        end

        if row.request_host then
          hosts = { row.request_host }
        end

        if row.request_path then
          uris = { row.request_path }
        end

        local _, err = dao.apis:update({
          hosts = hosts,
          uris = uris,
          strip_uri = row.strip_request_path,
          upstream_url = upstream_url,
        }, { id = row.id })
        if err then
          return err
        end
      end
    end,
    down = function(_, _, dao)
      -- re insert request_host and request_path from
      -- the first element of request_headers and
      -- request_uris

    end
  },
  {
    name = "2016-11-11-151900_new_apis_router_3",
    up = function(db, kong_config)
      local keyspace_name = kong_config.cassandra_keyspace

      if db.major_version_n < 3 then
        local rows, err = db:query([[
          SELECT *
          FROM system.schema_columns
          WHERE keyspace_name = ']] .. keyspace_name .. [['
            AND columnfamily_name = 'apis'
            AND column_name IN ('request_host', 'request_path')
        ]])
        if err then
          return err
        end

        for i = 1, #rows do
          if rows[i].index_name then
            local res, err = db:query("DROP INDEX " .. rows[i].index_name)
            if not res then
              return err
            end
          end
        end

      else
        local rows, err = db:query([[
          SELECT *
          FROM system_schema.indexes
          WHERE keyspace_name = ']] .. keyspace_name .. [['
            AND table_name = 'apis'
        ]])
        if err then
          return err
        end

        for i = 1, #rows do
          if rows[i].options and
             rows[i].options.target == "request_host" or
             rows[i].options.target == "request_path" then

            local res, err = db:query("DROP INDEX " .. rows[i].index_name)
            if not res then
              return err
            end
          end
        end
      end

      local err = db:queries [[
        ALTER TABLE apis DROP request_host;
        ALTER TABLE apis DROP request_path;
        ALTER TABLE apis DROP strip_request_path;
      ]]
      if err then
        return err
      end
    end,
    down = [[
      ALTER TABLE apis ADD request_host text;
      ALTER TABLE apis ADD request_path text;
      ALTER TABLE apis ADD strip_request_path boolean;

      CREATE INDEX IF NOT EXISTS ON apis(request_host);
      CREATE INDEX IF NOT EXISTS ON apis(request_path);
    ]]
  },
  {
    name = "2017-01-24-132600_upstream_timeouts",
    up = [[
      ALTER TABLE apis ADD upstream_connect_timeout int;
      ALTER TABLE apis ADD upstream_send_timeout int;
      ALTER TABLE apis ADD upstream_read_timeout int;
    ]],
    down = [[
      ALTER TABLE apis DROP upstream_connect_timeout;
      ALTER TABLE apis DROP upstream_send_timeout;
      ALTER TABLE apis DROP upstream_read_timeout;
    ]]
  },
  {
    name = "2017-01-24-132600_upstream_timeouts_2",
    up = function(_, _, dao)
      local ok, err = dao.db:wait_for_schema_consensus()
      if not ok then
        return "failed to wait for schema consensus: " .. err
      end

      local rows, err = dao.db:query([[
        SELECT * FROM apis;
      ]])
      if err then
        return err
      end

      for _, row in ipairs(rows) do
        if not row.upstream_connect_timeout
          or not row.upstream_read_timeout
          or not row.upstream_send_timeout then

          local _, err = dao.apis:update({
            upstream_connect_timeout = 60000,
            upstream_send_timeout = 60000,
            upstream_read_timeout = 60000,
          }, { id = row.id })
          if err then
            return err
          end
        end
      end
    end,
    down = function(_, _, dao) end
  },
  {
    name = "2017-03-27-132300_anonymous",
    -- this should have been in 0.10, but instead goes into 0.10.1 as a bugfix
    up = function(db)
      for _, name in ipairs({
        "basic-auth",
        "hmac-auth",
        "jwt",
        "key-auth",
        "ldap-auth",
        "oauth2",
      }) do
        local coordinator = db:get_coordinator()
        for rows, err in coordinator:iterate([[
          SELECT * FROM plugins where name = ?
        ]], { name }) do
          if err then
            return err
          end

          for _, row in ipairs(rows) do
            local config
            if type(row.config) == "string" then
              config = cjson.decode(row.config)
            end
            if config and not config.anonymous then
              config.anonymous = ""
              local _
              _, err = db:query([[
                UPDATE plugins
                SET config = ?
                WHERE id = ?]], { cjson.encode(config), row.id })
              if err then
                return err
              end
            end
          end
        end
      end
    end,
    down = function(_, _, dao) end
  },
  {
    name = "2017-04-04-145100_cluster_events",
    up = [[
      CREATE TABLE IF NOT EXISTS cluster_events(
        channel text,
        at      timestamp,
        node_id uuid,
        data    text,
        id      uuid,
        nbf     timestamp,
        PRIMARY KEY ((channel), at, node_id, id)
      ) WITH default_time_to_live = 86400
         AND comment = 'Kong cluster events broadcasting and polling';
    ]],
  },
  {
    name = "2017-05-19-173100_remove_nodes_table",
    up = [[
      DROP INDEX IF EXISTS nodes_cluster_listening_address_idx;
      DROP TABLE nodes;
    ]],
  },
  {
    name = "2017-07-28-225000_balancer_orderlist_remove",
    up = [[
      ALTER TABLE upstreams DROP orderlist;
    ]],
    down = function(_, _, dao) end,  -- not implemented
    ignore_error = "orderlist was not found"
  },
  {
    name = "2017-11-07-192000_upstream_healthchecks",
    up = [[
      ALTER TABLE upstreams ADD healthchecks text;
    ]],
    down = [[
      ALTER TABLE upstreams DROP healthchecks;
    ]],
    ignore_error = "Invalid column name healthchecks"
  },
  {
    name = "2017-10-27-134100_consistent_hashing_1",
    up = [[
      ALTER TABLE upstreams ADD hash_on text;
      ALTER TABLE upstreams ADD hash_fallback text;
      ALTER TABLE upstreams ADD hash_on_header text;
      ALTER TABLE upstreams ADD hash_fallback_header text;
    ]],
    down = [[
      ALTER TABLE upstreams DROP hash_on;
      ALTER TABLE upstreams DROP hash_fallback;
      ALTER TABLE upstreams DROP hash_on_header;
      ALTER TABLE upstreams DROP hash_fallback_header;
    ]],
    ignore_error = "Invalid column name"
  },
  {
    name = "2017-11-07-192100_upstream_healthchecks_2",
    up = function(db, _, dao)
      local default = cjson.encode(dao.db.new_db.upstreams.schema.fields.healthchecks.default)
      local coordinator = dao.db:get_coordinator()
      for rows, err in coordinator:iterate([[SELECT * FROM upstreams;]]) do
        if err then
          return nil, nil, err
        end
        for _, row in ipairs(rows) do
          if not row.healthchecks then
            local _, err = db:query([[
              UPDATE upstreams
              SET healthchecks = ?
              WHERE id = ?]], { default, row.id })
            if err then
              return err
            end
          end
        end
      end
    end,
    down = function(_, _, dao) end
  },
  {
    name = "2017-10-27-134100_consistent_hashing_2",
    up = function(db, _, dao)
      local coordinator = dao.db:get_coordinator()
      for rows, err in coordinator:iterate([[SELECT * FROM upstreams;]]) do
        if err then
          return nil, nil, err
        end
        for _, row in ipairs(rows) do
          if not row.hash_on or not row.hash_fallback then
            local _, err = db:query([[
              UPDATE upstreams
              SET hash_on = ?, hash_fallback = ?
              WHERE id = ?]], { "none", "none", row.id })
            if err then
              return err
            end
          end
        end
      end
    end,
    down = function(_, _, dao) end  -- n.a. since the columns will be dropped
  },
  {
    name = "2017-09-14-140200_routes_and_services",
    up = [[
      CREATE TABLE IF NOT EXISTS routes (
          partition       text,
          id              uuid,
          created_at      timestamp,
          updated_at      timestamp,
          protocols       set<text>,
          methods         set<text>,
          hosts           list<text>,
          paths           list<text>,
          regex_priority  int,
          strip_path      boolean,
          preserve_host   boolean,

          service_id      uuid,

          PRIMARY KEY     (partition, id)
      );

      CREATE INDEX IF NOT EXISTS routes_service_id_idx ON routes(service_id);

      CREATE TABLE IF NOT EXISTS services (
          partition       text,
          id              uuid,
          created_at      timestamp,
          updated_at      timestamp,
          name            text,
          protocol        text,
          host            text,
          port            int,
          path            text,
          retries         int,
          connect_timeout int,
          write_timeout   int,
          read_timeout    int,

          PRIMARY KEY (partition, id)
      );

      CREATE INDEX IF NOT EXISTS services_name_idx ON services(name);
    ]],
    down = nil
  },
  {
    name = "2017-10-25-180700_plugins_routes_and_services",
    up = [[
      ALTER TABLE plugins ADD route_id uuid;
      ALTER TABLE plugins ADD service_id uuid;

      CREATE INDEX IF NOT EXISTS ON plugins(route_id);
      CREATE INDEX IF NOT EXISTS ON plugins(service_id);
    ]],
    down = nil
  },
  {
    name = "2018-02-23-142400_targets_add_index",
    up = [[
      CREATE INDEX IF NOT EXISTS ON targets(target);
    ]],
    down = nil
  },
  {
    name = "2018-03-22-141700_create_new_ssl_tables",
    up = [[
      CREATE TABLE IF NOT EXISTS certificates(
        partition text,
        id uuid,
        cert text,
        key text,
        created_at timestamp,
        PRIMARY KEY (partition, id)
      );

      CREATE TABLE IF NOT EXISTS snis(
        partition text,
        id uuid,
        name text,
        certificate_id uuid,
        created_at timestamp,
        PRIMARY KEY (partition, id)
      );

      CREATE INDEX IF NOT EXISTS snis_name_idx ON snis(name);
      CREATE INDEX IF NOT EXISTS snis_certificate_id_idx ON snis(certificate_id);
    ]],
    down = nil
  },
  {
    name = "2018-03-26-234600_copy_records_to_new_ssl_tables",
    up = function(_, _, dao)
      local ssl_certificates_def = {
        name    = "ssl_certificates",
        columns = {
          id         = "uuid",
          cert       = "text",
          key        = "text",
          created_at = "timestamp",
        },
        partition_keys = { "id" },
      }

      local certificates_def = {
        name    = "certificates",
        columns = {
          partition  = "text",
          id         = "uuid",
          cert       = "text",
          key        = "text",
          created_at = "timestamp",
        },
        partition_keys = { "partition", "id" },
      }

      local _, err = migration_helpers.cassandra.copy_records(dao,
        ssl_certificates_def,
        certificates_def, {
          partition  = function() return cassandra.text("certificates") end,
          id         = "id",
          cert       = "cert",
          key        = "key",
          created_at = "created_at",
        })
      if err then
        return err
      end

      local ssl_servers_names_def = {
        name    = "ssl_servers_names",
        columns = {
          name       = "text",
          ssl_certificate_id = "uuid",
          created_at = "timestamp",
        },
        partition_keys = { "name", "ssl_certificate_id" },
      }

      local snis_def = {
        name    = "snis",
        columns = {
          partition      = "text",
          id             = "uuid",
          name           = "text",
          certificate_id = "uuid",
          created_at     = "timestamp",
        },
        partition_keys = { "partition", "id" },
      }

      local _, err = migration_helpers.cassandra.copy_records(dao,
        ssl_servers_names_def,
        snis_def, {
          partition      = function() return cassandra.text("snis") end,
          id             = function() return cassandra.uuid(utils.uuid()) end,
          name           = "name",
          certificate_id = "ssl_certificate_id",
          created_at     = "created_at",
        })
      if err then
        return err
      end
    end,
    down = nil
  },
  { name = "2018-03-27-002500_drop_old_ssl_tables",
    up = [[
      DROP INDEX ssl_servers_names_ssl_certificate_id_idx;
      DROP TABLE ssl_certificates;
      DROP TABLE ssl_servers_names;
    ]],
    down = nil,
  },
  {
    name = "2018-03-16-160000_index_consumers",
    up = [[
      CREATE INDEX IF NOT EXISTS ON consumers(custom_id);
      CREATE INDEX IF NOT EXISTS ON consumers(username);
    ]]
  },
  {
    name = "2018-05-17-173100_hash_on_cookie",
    up = [[
      ALTER TABLE upstreams ADD hash_on_cookie text;
      ALTER TABLE upstreams ADD hash_on_cookie_path text;
    ]],
    down = [[
      ALTER TABLE upstreams DROP hash_on_cookie;
      ALTER TABLE upstreams DROP hash_on_cookie_path;
    ]],
    ignore_error = "Invalid column name hash_on_cookie",
  },
  {
    name = "2018-08-06-000001_create_plugins_temp_table",
    up = [[
      CREATE TABLE IF NOT EXISTS plugins_temp(
        id uuid,
        created_at timestamp,
        api_id uuid,
        route_id uuid,
        service_id uuid,
        consumer_id uuid,
        name text,
        config text, -- serialized plugin configuration
        enabled boolean,
        cache_key text,
        PRIMARY KEY (id)
      );
    ]],
    down = nil
  },
  {
    name = "2018-08-06-000002_copy_records_to_plugins_temp",
    up = function(_, _, dao)
      local plugins_def = {
        name    = "plugins",
        columns = {
          id = "uuid",
          name = "text",
          config = "text",
          api_id = "uuid",
          route_id = "uuid",
          service_id = "uuid",
          consumer_id = "uuid",
          created_at = "timestamp",
          enabled = "boolean",
        },
        partition_keys = {},
      }
      local plugins_temp_def = {
        name    = "plugins_temp",
        columns = {
          id = "uuid",
          name = "text",
          config = "text",
          api_id = "uuid",
          route_id = "uuid",
          service_id = "uuid",
          consumer_id = "uuid",
          created_at = "timestamp",
          enabled = "boolean",
          cache_key = "text",
        },
        partition_keys = {},
      }
      local _, err = migration_helpers.cassandra.copy_records(dao,
        plugins_def,
        plugins_temp_def, {
          id = "id",
          name = "name",
          config = "config",
          api_id = "api_id",
          route_id = "route_id",
          service_id = "service_id",
          consumer_id = "consumer_id",
          created_at = "created_at",
          enabled = "enabled",
          cache_key = function(row)
            return table.concat({
              "plugins",
              row.name,
              row.route_id or "",
              row.service_id or "",
              row.consumer_id or "",
              row.api_id or ""
            }, ":")
          end,
        })
      if err then
        return err
      end
    end,
    down = nil
  },
  { name = "2018-08-06-000003_drop_plugins",
    up = [[
      DROP INDEX plugins_name_idx;
      DROP INDEX plugins_api_id_idx;
      DROP INDEX plugins_route_id_idx;
      DROP INDEX plugins_service_id_idx;
      DROP INDEX plugins_consumer_id_idx;
      DROP TABLE plugins;
    ]],
    down = nil,
  },
  {
    name = "2018-08-06-000004_create_plugins_table_with_fixed_pk",
    up = [[
      CREATE TABLE IF NOT EXISTS plugins(
        id uuid,
        created_at timestamp,
        api_id uuid,
        route_id uuid,
        service_id uuid,
        consumer_id uuid,
        name text,
        config text, -- serialized plugin configuration
        enabled boolean,
        cache_key text,
        PRIMARY KEY (id)
      );

      CREATE INDEX IF NOT EXISTS ON plugins(name);
      CREATE INDEX IF NOT EXISTS ON plugins(api_id);
      CREATE INDEX IF NOT EXISTS ON plugins(route_id);
      CREATE INDEX IF NOT EXISTS ON plugins(service_id);
      CREATE INDEX IF NOT EXISTS ON plugins(consumer_id);
      CREATE INDEX IF NOT EXISTS ON plugins(cache_key);
    ]],
    down = nil
  },
  {
    name = "2018-08-06-000005_copy_records_to_plugins_temp",
    up = function(_, _, dao)
      local plugins_temp_def = {
        name    = "plugins_temp",
        columns = {
          id = "uuid",
          name = "text",
          config = "text",
          api_id = "uuid",
          route_id = "uuid",
          service_id = "uuid",
          consumer_id = "uuid",
          created_at = "timestamp",
          enabled = "boolean",
          cache_key = "text",
        },
        partition_keys = {},
      }
      local plugins_def = {
        name    = "plugins",
        columns = {
          id = "uuid",
          name = "text",
          config = "text",
          api_id = "uuid",
          route_id = "uuid",
          service_id = "uuid",
          consumer_id = "uuid",
          created_at = "timestamp",
          enabled = "boolean",
          cache_key = "text",
        },
        partition_keys = {},
      }
      local _, err = migration_helpers.cassandra.copy_records(dao,
        plugins_temp_def,
        plugins_def, {
          id = "id",
          name = "name",
          config = "config",
          api_id = "api_id",
          route_id = "route_id",
          service_id = "service_id",
          consumer_id = "consumer_id",
          created_at = "created_at",
          enabled = "enabled",
          cache_key = "cache_key",
        })
      if err then
        return err
      end
    end,
    down = nil
  },
--  {
--    name = "2018-09-12-100000_add_name_to_routes",
--    up = [[
--      ALTER TABLE routes ADD name text;
--      CREATE INDEX IF NOT EXISTS routes_name_idx ON routes(name);
--    ]],
--    down = nil,
--  },
}
