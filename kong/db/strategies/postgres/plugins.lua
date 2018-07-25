local fmt = string.format


local Plugins = {}


local function convert_input(connector, value)
  return (value == nil or value == ngx.null)
         and "NULL"
         or connector:escape_literal(value)
end


local function convert_foreign(row, field, id_field)
  local id = row[id_field]
  if id == nil or id == ngx.null then
    row[field] = ngx.null
  else
    row[field] = { id = id }
  end
  row[id_field] = nil
end


local select_q = "SELECT * FROM plugins " ..
                 " WHERE name = %s" ..
                 " AND route_id = %s" ..
                 " AND service_id = %s" ..
                 " AND consumer_id = %s" ..
                 " AND api_id = %s"


function Plugins:select_by_ids(name, route_id, service_id, consumer_id, api_id)
  local connector = self.connector

  local sql = fmt(select_q,
    convert_input(connector, name),
    convert_input(connector, route_id),
    convert_input(connector, service_id),
    convert_input(connector, consumer_id),
    convert_input(connector, api_id)
  )

  local res, err = connector:query(sql)
  if not res then
    return connector:toerror(self, err)
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
