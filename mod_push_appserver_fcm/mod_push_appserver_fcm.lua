-- mod_push_appserver_fcm
--
-- Copyright (C) 2017 Thilo Molitor
--
-- This file is MIT/X11 licensed.
--
-- Submodule implementing FCM communication
--

-- imports
-- unlock prosody globals and allow ltn12 to pollute the global space
-- this fixes issue #8 in prosody 0.11, see also https://issues.prosody.im/1033
prosody.unlock_globals()
require "ltn12";
prosody.lock_globals()
local https = require "ssl.https";
local string = require "string";
local t_remove = table.remove;
local datetime = require "util.datetime";
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
local function send_request(data)
	local respbody = {} -- for the response body
	prosody.unlock_globals();	-- unlock globals (https.request() tries to access global PROXY)
	local result, status_code, headers, status_line = https.request({
		method = "POST",
		url = push_endpoint,
		source = ltn12.source.string(data),
		headers = {
			["authorization"] = "key="..tostring(fcm_key),
			["content-type"] = "application/json",
			["content-length"] = tostring(#data)
		},
		sink = ltn12.sink.table(respbody),
		-- luasec tls options
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
		},
	});
	prosody.lock_globals();		-- lock globals again
	if not result then return nil, status_code; end		-- status_code contains the error message in case of failure
	-- return body as string by concatenating table filled by sink
	return table.concat(respbody), status_code, status_line, headers;
end

-- handlers
local function fcm_handler(event)
	local settings = event.settings;
	local data = {
		["to"] = tostring(settings["token"]),
		["collapse_key"] = "mod_push_appserver_fcm.collapse",
		["priority"] = (push_priority=="high" and "high" or "normal"),
		["data"] = {},
	};
	if push_ttl and push_ttl > 0 then data["time_to_live"] = push_ttl; end		-- ttl is optional (google's default: 4 weeks)
	
	data = json.encode(data);
	module:log("debug", "sending to %s, json string: %s", push_endpoint, data);
	local response, status_code, status_line = send_request(data);
	if not response then
		module:log("error", "Could not send FCM request: %s", tostring(status_code));
		return tostring(status_code);		-- return error message
	end
	module:log("debug", "response status code: %s, raw response body: %s", tostring(status_code), response);
	
	if status_code ~= 200 then
		local fcm_error;
		if status_code == 400 then fcm_error="Invalid JSON or unknown fields."; end
		if status_code == 401 then fcm_error="There was an error authenticating the sender account."; end
		if status_code >= 500 and status_code < 600 then fcm_error="Internal server error, please retry again later."; end
		module:log("error", "Got FCM error: %s", fcm_error);
		return fcm_error;
	end
	response = json.decode(response);
	module:log("debug", "decoded: %s", pretty.write(response));
	
	-- handle errors
	if response.failure > 0 then
		module:log("error", "FCM returned %s failures:", tostring(response.failure));
		local fcm_error = true;
		for k, result in pairs(response.results) do
			if result.error and #result.error then
				module:log("error", "Got FCM error:", result.error);
				fcm_error = tostring(result.error);		-- return last error to mod_push_appserver
			end
		end
		return fcm_error;
	end
	
	-- handle success
	for k, result in pairs(response.results) do
		if result.message_id then
			module:log("debug", "got FCM message id: '%s'", tostring(result.message_id));
		end
	end
	return false;	-- no error occured
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
