local cassandra = require "cassandra"


local fmt = string.format
local null = ngx.null
local concat = table.concat
local insert = table.insert


local Plugins = {}


local function convert_foreign(row, field, id_field)
  local id = row[id_field]
  if id == nil or id == null then
    row[field] = null
  else
    row[field] = { id = id }
  end
  row[id_field] = nil
end


function Plugins:select_by_ids(name, route_id, service_id, consumer_id, api_id)
  local connector = self.connector
  local cluster = connector.cluster
  local errors = self.errors

  local res   = {}
  local count = 0

  local exp = {}
  local args = {}
  if name ~= nil and name ~= null then
    insert(exp, "name = ?")
    insert(args, cassandra.text(name))
  end
  if route_id ~= nil and route_id ~= null then
    insert(exp, "route_id = ?")
    insert(args, cassandra.uuid(route_id))
  end
  if service_id ~= nil and service_id ~= null then
    insert(exp, "service_id = ?")
    insert(args, cassandra.uuid(service_id))
  end
  if consumer_id ~= nil and consumer_id ~= null then
    insert(exp, "consumer_id = ?")
    insert(args, cassandra.uuid(consumer_id))
  end
  if api_id ~= nil and api_id ~= null then
    insert(exp, "api_id = ?")
    insert(args, cassandra.uuid(api_id))
  end

  local select_q = "SELECT * FROM plugins WHERE " ..
                   concat(exp, " AND ") ..
                   " ALLOW FILTERING"
  for rows, err in cluster:iterate(select_q, args) do
    if err then
      return nil,
             errors:database_error(fmt("could not fetch plugins: %s", err))
    end

    for i = 1, #rows do
      count = count + 1
      res[count] = rows[i]
    end
  end

  for _, row in ipairs(res) do
    convert_foreign(row, "api", "api_id")
    convert_foreign(row, "route", "route_id")
    convert_foreign(row, "service", "service_id")
    convert_foreign(row, "consumer", "consumer_id")
  end

  return res
end


return Plugins
