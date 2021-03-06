local Schema = require("kong.db.schema")

local Entity = {}


local entity_errors = {
  NO_NILABLE = "%s: Entities cannot have nilable types.",
  NO_FUNCTIONS = "%s: Entities cannot have function types.",
  MAP_KEY_STRINGS_ONLY = "%s: Entities map keys must be strings.",
  AGGREGATE_ON_BASE_TYPES_ONLY = "%s: Entities aggregates are only allowed on base types.",
}


local base_types = {
  string = true,
  number = true,
  boolean = true,
  integer = true,
}

-- Make records in Entities non-nullable by default,
-- so that they return their full structure on API queries.
local function make_records_non_nullable(field)
  if field.nullable == nil then
    field.nullable = false
  end
  for _, f in Schema.each_field(field) do
    if f.type == "record" then
      make_records_non_nullable(f)
    end
  end
end

function Entity.new(definition)

  local self, err = Schema.new(definition)
  if not self then
    return nil, err
  end

  for name, field in self:each_field() do
    if field.nilable then
      return nil, entity_errors.NO_NILABLE:format(name)
    end

    if field.abstract then
      goto continue
    end

    if field.type == "map" then
      if field.keys.type ~= "string" then
        return nil, entity_errors.MAP_KEY_STRINGS_ONLY:format(name)
      end
      if not base_types[field.values.type] then
        return nil, entity_errors.AGGREGATE_ON_BASE_TYPES_ONLY:format(name)
      end

    elseif field.type == "array" or field.type == "set" then
      if not base_types[field.elements.type] then
        return nil, entity_errors.AGGREGATE_ON_BASE_TYPES_ONLY:format(name)
      end

    elseif field.type == "record" then
      make_records_non_nullable(field)

    elseif field.type == "function" then
      return nil, entity_errors.NO_FUNCTIONS:format(name)
    end

    ::continue::
  end

  return self
end


function Entity.new_subschema(schema, key, definition)
  make_records_non_nullable(definition)
  definition.nullable = nil
  return Schema.new_subschema(schema, key, definition)
end


return Entity
