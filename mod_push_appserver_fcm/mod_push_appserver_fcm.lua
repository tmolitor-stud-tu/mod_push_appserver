-- mod_push_appserver_fcm
--
-- Copyright (C) 2017 Thilo Molitor
--
-- This file is MIT/X11 licensed.
--
-- Submodule implementing FCM communication
--

local http = require "net.http";
local json = require "util.json";
local pretty = require "pl.pretty";

-- this is the master module
module:depends("push_appserver");

-- configuration
local fcm_key = module:get_option_string("push_appserver_fcm_key", nil);						--push api key (no default)
local capath = module:get_option_string("push_appserver_fcm_capath", "/etc/ssl/certs");			--ca path on debian systems
local ciphers = module:get_option_string("push_appserver_fcm_ciphers", 
	"ECDHE-RSA-AES256-GCM-SHA384:"..
	"ECDHE-ECDSA-AES256-GCM-SHA384:"..
	"ECDHE-RSA-AES128-GCM-SHA256:"..
	"ECDHE-ECDSA-AES128-GCM-SHA256"
);	--supported ciphers
local push_ttl = module:get_option_number("push_appserver_fcm_push_ttl", nil);					--no ttl (equals 4 weeks)
local push_priority = module:get_option_string("push_appserver_fcm_push_priority", "high");		--high priority pushes (can be "high" or "normal")
local push_endpoint = "https://fcm.googleapis.com/fcm/send";

-- high level network (https) functions
local function send_request(data, callback)
	local x = {
		sslctx = {
			mode = "client",
			protocol = "tlsv1_2",
			verify = {"peer", "fail_if_no_peer_cert"},
			capath = capath,
			ciphers = ciphers,
			options = {
				"no_sslv2",
				"no_sslv3",
				"no_ticket",
				"no_compression",
				"cipher_server_preference",
				"single_dh_use",
				"single_ecdh_use",
			}
		},
		headers = {
			["Authorization"] = "key="..tostring(fcm_key),
			["Content-Type"] = "application/json",
		},
		body = data
	};
	local ok, err = http.request(push_endpoint, x, callback);
	if not ok then
		callback(nil, err);
	end
end

-- handlers
local function fcm_handler(event)
	local settings, summary, async_callback = event.settings, event.summary, event.async_callback;
	local data = {
		["to"] = tostring(settings["token"]),
		["collapse_key"] = "mod_push_appserver_fcm.collapse",
		["priority"] = (push_priority=="high" and "high" or "normal"),
		["data"] = {},
	};
	if push_ttl and push_ttl > 0 then data["time_to_live"] = push_ttl; end		-- ttl is optional (google's default: 4 weeks)
	
	local callback = function(response, status_code)
		if not response then
			module:log("error", "Could not send FCM request: %s", tostring(status_code));
			async_callback(tostring(status_code));		-- return error message
			return;
		end
		module:log("debug", "response status code: %s, raw response body: %s", tostring(status_code), response);
		
		if status_code ~= 200 then
			local fcm_error = "Unknown FCM error.";
			if status_code == 400 then fcm_error="Invalid JSON or unknown fields."; end
			if status_code == 401 then fcm_error="There was an error authenticating the sender account."; end
			if status_code >= 500 and status_code < 600 then fcm_error="Internal server error, please retry again later."; end
			module:log("error", "Got FCM error: '%s'", fcm_error);
			async_callback(fcm_error);
			return;
		end
		response = json.decode(response);
		module:log("debug", "decoded: %s", pretty.write(response));
		
		-- handle errors
		if response.failure > 0 then
			module:log("warn", "FCM returned %s failures:", tostring(response.failure));
			local fcm_error = true;
			for k, result in pairs(response.results) do
				if result.error and #tostring(result.error)then
					module:log("warn", "Got FCM error: '%s'", tostring(result.error));
					fcm_error = tostring(result.error);		-- return last error to mod_push_appserver
					if result.error == "NotRegistered" then
						-- add unregister token to prosody event queue
						module:log("debug", "Adding unregister-push-token to prosody event queue...");
						module:add_timer(1e-06, function()
							module:log("warn", "Unregistering failing FCM token %s", tostring(settings["token"]))
							module:fire_event("unregister-push-token", {token = tostring(settings["token"]), type = "fcm"})
						end)
					end
				end
			end
			async_callback(fcm_error);
			return;
		end
		
		-- handle success
		for k, result in pairs(response.results) do
			if result.message_id then
				module:log("debug", "got FCM message id: '%s'", tostring(result.message_id));
			end
		end
		
		async_callback(false);		-- --> no error occured
		return;
	end
	
	data = json.encode(data);
	module:log("debug", "sending to %s, json string: %s", push_endpoint, data);
	send_request(data, callback);
	return true;		-- signal the use of use async iq responses
end

-- setup
module:hook("incoming-push-to-fcm", fcm_handler);
module:log("info", "Appserver FCM submodule loaded");
function module.unload()
	if module.unhook then
		module:unhook("incoming-push-to-fcm", fcm_handler);
	end
	module:log("info", "Appserver FCM submodule unloaded");
end
