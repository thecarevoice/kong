local api_helpers = require "kong.api.api_helpers"
local endpoints   = require "kong.api.endpoints"
local reports     = require "kong.reports"
local utils       = require "kong.tools.utils"
local kong        = kong


local get_plugin = endpoints.get_collection_endpoint(kong.db.plugins.schema,
                                                     kong.db.routes.schema,
                                                     "route")
local post_plugin = endpoints.post_collection_endpoint(kong.db.plugins.schema,
                                                       kong.db.routes.schema,
                                                       "route")


return {
  ["/routes/:routes/service"] = {
    PATCH = function(self, _, _, parent)
      api_helpers.resolve_url_params(self)
      return parent()
    end,
  },

  ["/routes/:routes/plugins"] = {
    GET = get_plugin,

    POST = function(self, db, helpers)
      local post_process = function(data)
        local r_data = utils.deep_copy(data)
        r_data.config = nil
        r_data.e = "r"
        reports.send("api", r_data)
      end
      return post_plugin(self, db, helpers, post_process)
    end,
  },
}
