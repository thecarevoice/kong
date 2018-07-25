local typedefs = require "kong.db.schema.typedefs"


return {
  name = "plugins",
  primary_key = { "id", "name" },
  dao = "kong.db.dao.plugins",

  subschema_key = "name",

  fields = {
    { id = typedefs.uuid, },
    { name = { type = "string", required = true, }, },
    { created_at = typedefs.auto_timestamp },
    { api = { type = "foreign", reference = "apis", default = ngx.null }, },
    { route = { type = "foreign", reference = "routes", default = ngx.null }, },
    { service = { type = "foreign", reference = "services", default = ngx.null }, },
    { consumer = { type = "foreign", reference = "consumers", default = ngx.null }, },
    { config = { type = "record", abstract = true, }, },
    { enabled = { type = "boolean", default = true, }, },
  },

  entity_checks = {
    { composite_unique = { "name", "api", "route", "service", "consumer" } },
  },

}
