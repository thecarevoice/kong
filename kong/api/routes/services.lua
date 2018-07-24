local api_helpers = require "kong.api.api_helpers"
local endpoints   = require "kong.api.endpoints"
local reports     = require "kong.reports"
local utils       = require "kong.tools.utils"
local kong        = kong


local get_plugin = endpoints.get_collection_endpoint(kong.db.plugins.schema,
                                                     kong.db.services.schema,
                                                     "service")
local post_plugin = endpoints.post_collection_endpoint(kong.db.plugins.schema,
                                                       kong.db.services.schema,
                                                       "service")


return {
  ["/services"] = {
    POST = function(self, _, _, parent)
      api_helpers.resolve_url_params(self)
      return parent()
    end,
  },

  ["/services/:services"] = {
    PUT = function(self, _, _, parent)
      api_helpers.resolve_url_params(self)
      return parent()
    end,
    PATCH = function(self, _, _, parent)
      api_helpers.resolve_url_params(self)
      return parent()
    end,
  },

  ["/services/:services/plugins"] = {
    GET = get_plugin,

    POST = function(self, db, helpers)
      local post_process = function(data)
        local r_data = utils.deep_copy(data)
        r_data.config = nil
        r_data.e = "s"
        reports.send("api", r_data)
      end
      return post_plugin(self, db, helpers, post_process)
    end,
  },
}
