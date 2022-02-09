return function(params)
	local store = module:open_store();
	local api = {};
	function api:get(node)
		local settings, err = store:get(node);
		if not settings and err then
			module:log("error", "Error reading push notification storage for node '%s': %s", node, tostring(err));
			return nil, false;
		end
		if not settings then settings = {} end
		return settings, true;
	end
	function api:set(node, data)
		local settings = api:get(node);		-- load node's data
		local ok, err = store:set(node, data);
		if not ok then
			module:log("error", "Error writing push notification storage for node '%s': %s", node, tostring(err));
			return false;
		end
		return true;
	end
	function api:list()
		return store:users();
	end
	return api;
end;