local typedefs = require "kong.db.schema.typedefs"

return {
  name = "apis",
  legacy = true,
  primary_key  = { "id" },

  fields = {
    { id = typedefs.uuid, },
  },
}
