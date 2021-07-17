local time = require "util.time";

local distance = 0;
local api = {};
local data = {}

function api:set_distance(d)
	distance = d;
end

function api:incoming(id, callback)
	if not data[id] then data[id] = {}; end
	-- directly call callback() if the last call for this id was more than `distance` seconds away
	if not data[id]["last_call"] or time.now() > data[id]["last_call"] + distance  then
		data[id]["last_call"] = time.now();
		if data[id]["timer"] then data[id]["timer"]:stop(); data[id]["timer"] = nil; end
		module:log("info", "Calling callback directly");
		callback();
		return "allowed";
	-- use timer to delay second invocation
	elseif not data[id]["timer"] then
		data[id]["timer"] = module:add_timer(distance - (time.now() - data[id]["last_call"]), function()
			data[id]["timer"] = nil;
			data[id]["last_call"] = time.now();
			module:log("info", "Calling delayed callback");
			callback();
		end);
		return "delayed";
	-- ignore all other invocations until the delayed one fired
	else
		module:log("debug", "Ignoring incoming call");
		return "ignored";
	end
end

return api;
