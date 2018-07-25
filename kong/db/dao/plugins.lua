local Plugins = {}


function Plugins:select_by_ids(name, route_id, service_id, consumer_id, api_id)
  return self.strategy:select_by_ids(name, route_id, service_id, consumer_id, api_id)
end


return Plugins
