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
	function api:token2node(token)
		for node in store:users() do
			-- read data directly, we don't want to cache full copies of stale entries as api:get() would do
			local settings, err = store:get(node);
			if not settings and err then
				module:log("error", "Error reading push notification storage for node '%s': %s", node, tostring(err));
				settings = {};
			end
			if settings.token and settings.node and settings.token == token then return settings.node; end
		end
		return nil;
	end
	return api;
end;