local Endpoints = require "kong.api.endpoints"
local reports = require "kong.reports"
local utils = require "kong.tools.utils"
local kong = kong


local get_plugin = Endpoints.get_collection_endpoint(kong.db.plugins.schema,
                                                     kong.db.consumers.schema,
                                                     "consumer")
local post_plugin = Endpoints.post_collection_endpoint(kong.db.plugins.schema,
                                                       kong.db.consumers.schema,
                                                       "consumer")


local escape_uri   = ngx.escape_uri


return {

  ["/consumers"] = {
    GET = function(self, db, helpers)

      if self.params.custom_id then
        local consumer, _, err_t = db.consumers:select_by_custom_id(self.params.custom_id)
        if err_t then
          return Endpoints.handle_error(err_t)
        end

        return helpers.responses.send_HTTP_OK {
          data   = { consumer },
        }
      end

      local data, _, err_t, offset = db.consumers:page(self.args.size,
                                                       self.args.offset)
      if err_t then
        return Endpoints.handle_error(err_t)
      end

      local next_page = offset and "/consumers?offset=" .. escape_uri(offset)
                                or ngx.null

      return helpers.responses.send_HTTP_OK {
        data   = data,
        offset = offset,
        next   = next_page,
      }
    end,
  },

  ["/consumers/:consumers/plugins"] = {
    GET = get_plugin,

    POST = function(self, db, helpers)
      local post_process = function(data)
        local r_data = utils.deep_copy(data)
        r_data.config = nil
        r_data.e = "c"
        reports.send("api", r_data)
        return data
      end
      return post_plugin(self, db, helpers, post_process)
    end,
  },

  ["/consumers/:consumers/plugins/:id"] = {
    GET = function(self, db, helpers)
      --local pk = { id = self.params.id }

      local plugin, _, err_t = db.plugins:select_by_id(self.params.id)
      if err_t then
        return Endpoints.handle_error(err_t)
      end

      if plugin
         and type(plugin.consumer) == "table"
         and plugin.consumer.id ~= self.params.consumers then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      return helpers.responses.send_HTTP_OK(plugin)
    end,
  },

--  ["/consumers/:consumers/plugins"] = {
--    GET = Endpoints.get_collection_endpoint(kong.db.plugins.schema,
--                                            kong.db.consumers.schema,
--                                            "consumer"),
--    POST = Endpoints.post_collection_endpoint(kong.db.plugins.schema,
--                                              kong.db.consumers.schema,
--                                              "consumer"),
--  },
--
--  ["/consumers/:consumers/plugins/:id"] = {
--    before = function(self, dao_factory, helpers)
--      self.params.username_or_id = ngx.unescape_uri(self.params.consumers)
--      self.params.consumers = nil
--      crud.find_consumer_by_username_or_id(self, dao_factory, helpers)
--      crud.find_plugin_by_filter(self, dao_factory, {
--        consumer_id = self.consumer.id,
--        id          = self.params.id,
--      }, helpers)
--    end,
--
--    GET = function(self, dao_factory, helpers)
--      return helpers.responses.send_HTTP_OK(self.plugin)
--    end,
--
--    PATCH = function(self, dao_factory)
--      crud.patch(self.params, dao_factory.plugins, self.plugin)
--    end,
--
--    DELETE = function(self, dao_factory)
--      crud.delete(self.plugin, dao_factory.plugins)
--    end
--  },
}
