return function(params)
	local store = module:open_store();
	local cache = {};
	local token2node_cache = {};
	local api = {};
	function api:get(node)
		if not cache[node] then
			local err;
			cache[node], err = store:get(node);
			if not cache[node] and err then
				module:log("error", "Error reading push notification storage for node '%s': %s", node, tostring(err));
				cache[node] = {};
				return cache[node], false;
			end
		end
		if not cache[node] then cache[node] = {} end
		-- add entry to token2node cache, too
		if cache[node].token and cache[node].node then token2node_cache[cache[node].token] = cache[node].node; end
		return cache[node], true;
	end
	function api:set(node, data)
		local settings = api:get(node);		-- load node's data
		-- fill caches
		cache[node] = data;
		if settings.token and settings.node then token2node_cache[settings.token] = settings.node; end
		local ok, err = store:set(node, cache[node]);
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