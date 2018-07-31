local cjson = require "cjson"
local utils = require "kong.tools.utils"
local reports = require "kong.reports"
local singletons = require "kong.singletons"

--[[
-- Remove functions from a schema definition so that
-- cjson can encode the schema.
local function remove_functions(schema)
  local copy = {}
  for k, v in pairs(schema) do
    copy[k] =  (type(v) == "function" and "function")
            or (type(v) == "table"    and remove_functions(schema[k]))
            or v
  end
  return copy
end
]]

return {
  ["/plugins"] = {
    POST = function(_, _, _, parent)
      local post_process = function(data)
        local r_data = utils.deep_copy(data)
        r_data.config = nil
        if data.service.id then
          r_data.e = "s"
        elseif data.route.id then
          r_data.e = "r"
        elseif data.api.id then
          r_data.e = "a"
        end
        reports.send("api", r_data)
        return data
      end
      return parent(post_process)
    end,
  },

  --[[
  -- FIXME
  ["/plugins/schema/:name"] = {
    GET = function(self, dao_factory, helpers)
      local ok, plugin_schema = utils.load_module_if_exists("kong.plugins." .. self.params.name .. ".schema")
      if not ok then
        return helpers.responses.send_HTTP_NOT_FOUND("No plugin named '" .. self.params.name .. "'")
      end

      local copy = remove_functions(plugin_schema)

      return helpers.responses.send_HTTP_OK(copy)
    end
  },
  ]]

  ["/plugins/enabled"] = {
    GET = function(_, _, helpers)
      local enabled_plugins = setmetatable({}, cjson.empty_array_mt)
      for k in pairs(singletons.configuration.loaded_plugins) do
        enabled_plugins[#enabled_plugins+1] = k
      end
      return helpers.responses.send_HTTP_OK {
        enabled_plugins = enabled_plugins
      }
    end
  }
}
