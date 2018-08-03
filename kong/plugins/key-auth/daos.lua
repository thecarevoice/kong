local utils = require "kong.tools.utils"
local typedefs = require "kong.db.schema.typedefs"

local SCHEMA = {
  name = "keyauth_credentials",
  primary_key = { "id" },
  cache_key = { "key" },
  fields = {
    { id = typedefs.uuid, },
    -- FIXME change to typedefs.timestamp when merged
    { created_at  = { type = "number", timestamp = true, auto = true }, },
    { consumer = { type = "foreign", required = true, reference = "consumers" }, },
    { key = { type = "string", required = false, unique = true, default = utils.random_string }, },
  },
}

return { keyauth_credentials = SCHEMA }
