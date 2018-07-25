local constants = require "kong.constants"
local typedefs = require "kong.db.schema.typedefs"
local utils = require "kong.tools.utils"


local plugins_loader = {}


local ngx_log = ngx.log
local ngx_WARN = ngx.WARN
local ngx_DEBUG = ngx.DEBUG


local function validate_url(v)
  if v and type(v) == "string" then
    local parsed_url = require("socket.url").parse(v)
    if parsed_url and not parsed_url.path then
      parsed_url.path = "/"
    end
    return parsed_url and parsed_url.path and parsed_url.host and parsed_url.scheme
  end
end


local function convert_legacy_schema(name, old_schema)
  local new_schema = {
    name = name,
    fields = {
      config = {
        type = "record",
        fields = {}
      }
    },
  }
  for old_fname, old_fdata in pairs(old_schema.fields) do
    local new_fdata = {}
    local new_field = { [old_fname] = new_fdata }
    local elements = {}
    for k, v in pairs(old_fdata) do

      if k == "type" then
        if v == "url" then
          new_fdata.type = "string"
          new_fdata.custom_validator = validate_url

        elseif v == "table" then
          if old_fdata.schema.flexible then
            new_fdata.type = "map"
          else
            new_fdata.type = "record"
          end

        elseif v == "array" then
          new_fdata.type = "array"
          elements.type = "string"
          -- FIXME stored as JSON in old db

        elseif v == "timestamp" then
          new_fdata = typedefs.timestamp

        elseif v == "string" then
          new_fdata.type = v
          new_fdata.len_min = 0

        elseif v == "number"
            or v == "boolean" then
          new_fdata.type = v

        else
          return nil, "unkown legacy field type: " .. v
        end

      elseif k == "schema" then
        local rfields, err = convert_legacy_schema("fields", v)
        if err then
          return nil, err
        end
        rfields = rfields.fields.config.fields

        if v.flexible then
          new_fdata.keys = { type = "string" }
          new_fdata.values = {
            type = "record",
            fields = rfields,
          }
        else
          new_fdata.fields = rfields
        end

      elseif k == "immutable" then
        -- FIXME really ignore?
        ngx_log(ngx_DEBUG, "Ignoring 'immutable' property")

      elseif k == "enum" then
        if old_fdata.type == "array" then
          elements.one_of = v
        else
          new_fdata.one_of = v
        end

      elseif k == "default"
          or k == "required"
          or k == "unique" then
        new_fdata[k] = v

      elseif k == "func" then
        -- FIXME some will become custom validators, some entity checks
        ngx_log(ngx_WARN, "Ignoring 'func' property, validation will not run!")

      elseif k == "new_type" then
        new_field[old_fname] = v
        break

      else
        return nil, "unknown legacy field attribute: " .. require"inspect"(k)
      end

    end
    if new_fdata.type == "array" then
      new_fdata.elements = elements
    end
    table.insert(new_schema.fields.config.fields, new_field)
  end

  if old_schema.no_consumer then
    table.insert(new_schema.fields, { consumer = typedefs.no_consumer })
  end
print("CONVERTED ", name, " TO ", require"inspect"(new_schema))
  return new_schema
end


function plugins_loader.load_plugins(kong_conf, db)
  local in_db_plugins, sorted_plugins = {}, {}
  ngx_log(ngx_DEBUG, "Discovering used plugins")

  for row, err in db.plugins:each() do
    if err then
      return nil, tostring(err)
    end
    in_db_plugins[row.name] = true
  end

  -- check all plugins in DB are enabled/installed
  for plugin in pairs(in_db_plugins) do
    if not kong_conf.loaded_plugins[plugin] then
      return nil, plugin .. " plugin is in use but not enabled"
    end
  end

  -- load installed plugins
  for plugin in pairs(kong_conf.loaded_plugins) do
    if constants.DEPRECATED_PLUGINS[plugin] then
      ngx_log(ngx_WARN, "plugin '", plugin, "' has been deprecated")
    end

    -- NOTE: no version _G.kong (nor PDK) in plugins main chunk

    local ok, handler = utils.load_module_if_exists("kong.plugins." .. plugin .. ".handler")
    if not ok then
      return nil, plugin .. " plugin is enabled but not installed;\n" .. handler
    end

    local schema
    ok, schema = utils.load_module_if_exists("kong.plugins." .. plugin .. ".schema")
    if not ok then
      return nil, "no configuration schema found for plugin: " .. plugin
    end

    local err

    if not schema.name then
      schema, err = convert_legacy_schema(plugin, schema)
      if err then
        return nil, "failed converting legacy schema for " .. plugin .. ": " .. err
      end
    end

    ok, err = db.plugins.schema:new_subschema(plugin, schema)
    if not ok then
      return nil, "error initializing schema for plugin: " .. err
    end
print("NEW SUBSCHEMA ", plugin, " IN ", tostring(db.plugins.schema))

    ngx_log(ngx_DEBUG, "Loading plugin: " .. plugin)

    sorted_plugins[#sorted_plugins+1] = {
      name = plugin,
      handler = handler(),
      schema = schema
    }
  end

  -- sort plugins by order of execution
  table.sort(sorted_plugins, function(a, b)
    local priority_a = a.handler.PRIORITY or 0
    local priority_b = b.handler.PRIORITY or 0
    return priority_a > priority_b
  end)

  -- add reports plugin if not disabled
  if kong_conf.anonymous_reports then
    local reports = require "kong.reports"

    local db_infos = db.old_dao:infos()
    reports.add_ping_value("database", kong_conf.database)
    reports.add_ping_value("database_version", db_infos.version)

    reports.toggle(true)

    sorted_plugins[#sorted_plugins+1] = {
      name = "reports",
      handler = reports,
      schema = {},
    }
  end

  return sorted_plugins
end


return plugins_loader
