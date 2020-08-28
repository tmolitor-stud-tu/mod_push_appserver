-- mod_push_appserver_apns
--
-- Copyright (C) 2017 Thilo Molitor
--
-- This file is MIT/X11 licensed.
--
-- Submodule implementing APNS communication
--

-- imports
local cq = require "net.cqueues".cq;
local http_client = require "http.client";
local new_headers = require "http.headers".new;
local ce = require "cqueues.errno";
local new_tls_context = require "http.tls".new_client_context;
local openssl_ctx = require "openssl.ssl.context";
local x509 = require "openssl.x509";
local pkey = require "openssl.pkey";
local json = require "util.json";
local pretty = require "pl.pretty";

-- this is the master module
module:depends("push_appserver");

-- configuration
local test_environment = false;
local apns_cert = module:get_option_string("push_appserver_apns_cert", nil);							--push certificate (no default)
local apns_key = module:get_option_string("push_appserver_apns_key", nil);								--push certificate key (no default)
local topic = module:get_option_string("push_appserver_apns_topic", nil);								--apns topic: app bundle id (no default)
local capath = module:get_option_string("push_appserver_apns_capath", "/etc/ssl/certs");				--ca path on debian systems
local ciphers = module:get_option_string("push_appserver_apns_ciphers",
	"ECDHE-RSA-AES256-GCM-SHA384:"..
	"ECDHE-ECDSA-AES256-GCM-SHA384:"..
	"ECDHE-RSA-AES128-GCM-SHA256:"..
	"ECDHE-ECDSA-AES128-GCM-SHA256"
);
local mutable_content = module:get_option_boolean("push_appserver_apns_mutable_content", true);			--flag high prio pushes as mutable content
local push_ttl = module:get_option_number("push_appserver_apns_push_ttl", os.time() + (4*7*24*3600));	--now + 4 weeks
local push_priority = module:get_option_string("push_appserver_apns_push_priority", "auto");			--automatically decide push priority
local sandbox = module:get_option_boolean("push_appserver_apns_sandbox", true);							--use APNS sandbox
local push_host = sandbox and "api.sandbox.push.apple.com" or "api.push.apple.com";
local push_port = 443;
if test_environment then push_host = "localhost"; end
local default_tls_options = openssl_ctx.OP_NO_COMPRESSION + openssl_ctx.OP_SINGLE_ECDH_USE + openssl_ctx.OP_NO_SSLv2 + openssl_ctx.OP_NO_SSLv3;

-- global state
local connection = nil;
local certstring;
local keystring;

-- general utility functions
local function non_final_status(status)
	return status:sub(1, 1) == "1" and status ~= "101"
end
local function readAll(file)
    local f = assert(io.open(file, "rb"));
    local content = f:read("*all");
    f:close();
    return content;
end
local function unregister_token(token)
	-- add unregister token to prosody event queue
	module:log("debug", "Adding unregister-push-token to prosody event queue...");
	module:add_timer(1e-06, function()
		module:log("warn", "Unregistering failing APNS token %s", tostring(token))
		module:fire_event("unregister-push-token", {token = tostring(token), type = "apns"})
	end)
end

-- handlers
local function apns_handler(event)
	local settings, summary, async_callback = event.settings, event.summary, event.async_callback;
	-- prepare data to send (using latest binary format, not the legacy binary format or the new http/2 format)
	local payload;
	local priority = push_priority;
	if push_priority == "auto" then
		priority = (summary and summary["last-message-body"] ~= nil) and "high" or "silent";
	end
	if priority == "high" then
		payload = '{"aps":{'..(mutable_content and '"mutable-content":"1",' or '')..'"alert":{"title":"New Message", "body":"New Message"}, "sound":"default"}}';
	else
		payload = '{"aps":{"content-available":1}}';
	end
	
	cq:wrap(function()
		-- create new tls context and connection if not already connected
		if connection == nil then
			module:log("debug", "Creating new connection to APNS server '%s'...", push_host);
			
			-- create new tls context
			local ctx = openssl_ctx.new("TLSv1_2", false);
			ctx:setCipherList(ciphers);
			ctx:setOptions(default_tls_options);
			ctx:setEphemeralKey(pkey.new{ type = "EC", curve = "prime256v1" });
			local store = ctx:getStore();
			store:add(capath);
			ctx:setVerify(openssl_ctx.VERIFY_PEER);
			if test_environment then ctx:setVerify(openssl_ctx.VERIFY_NONE); end
			ctx:setCertificate(x509.new(certstring));
			ctx:setPrivateKey(pkey.new(keystring));
			
			-- create new connection
			local err, errno;
			connection, err, errno = http_client.connect({
				host = push_host;
				port = push_port;
				tls = true;
				version = 2;
				ctx = ctx;
			});
			if connection == nil then
				module:log("error", "APNS connect error %s: %s", tostring(errno), tostring(err));
				async_callback("Error connecting to APNS server");
				return;
			end
		end
		
		-- create new stream for our request
		module:log("debug", "Creating new http/2 stream...");
		local stream, err, errno, ok;
		stream, err, errno = connection:new_stream();
		if stream == nil then
			module:log("error", "APNS new_stream error %s: %s", tostring(errno), tostring(err));
			async_callback("Error creating new APNS request");
			connection = nil;
			return;
		end
		
		-- write request
		module:log("debug", "Writing http/2 request...");
		local req_headers = new_headers();
		req_headers:append(":method", "POST");
		req_headers:append(":scheme", "https");
		req_headers:upsert(":path", "/3/device/"..settings["token"]);
		req_headers:upsert("content-length", string.format("%d", #payload));
		req_headers:upsert("apns-topic", priority == "voip" and topic..".voip" or topic);
		req_headers:upsert("apns-expiration", tostring(push_ttl));
		if priority == "high" then
			module:log("debug", "high: push_type: alert, priority: 10, collapse-id: xmpp-body-push");
			req_headers:upsert("apns-push-type", "alert");
			req_headers:upsert("apns-priority", "10");
			req_headers:upsert("apns-collapse-id", "xmpp-body-push");
		elseif priority == "voip" then
			module:log("debug", "voip: push_type: alert, priority: 10, collapse-id: xmpp-voip-push");
			req_headers:upsert("apns-push-type", "alert");
			req_headers:upsert("apns-priority", "10");
			req_headers:upsert("apns-collapse-id", "xmpp-voip-push");
		else
			module:log("debug", "silent: push_type: background, priority: 5, collapse-id: xmpp-nobody-push");
			req_headers:upsert("apns-push-type", "background");
			req_headers:upsert("apns-priority", "5");
			req_headers:upsert("apns-collapse-id", "xmpp-nonbody-push");
		end
		ok, err, errno = stream:write_headers(req_headers, false);
		if not ok then
			stream:shutdown();
			module:log("error", "APNS write_headers error %s: %s", tostring(errno), tostring(err));
			async_callback("Error writing request headers to APNS server");
			connection = nil;
			return;
		end
		module:log("debug", "payload: %s", payload);
		ok, err, errno = stream:write_body_from_string(payload)
		if not ok then
			stream:shutdown();
			module:log("error", "APNS write_body_from_string error %s: %s", tostring(errno), tostring(err));
			async_callback("Error writing request body to APNS server");
			connection = nil;
			return;
		end
		
		-- read response
		module:log("debug", "Reading http/2 response...");
		local headers;
		-- Skip through 1xx informational headers.
		-- From RFC 7231 Section 6.2: "A user agent MAY ignore unexpected 1xx responses"
		repeat
			headers, err, errno = stream:get_headers();
			if headers == nil then
				stream:shutdown();
				module:log("error", "APNS get_headers error %s: %s", tostring(errno or ce.EPIPE), tostring(err or ce.strerror(ce.EPIPE)));
				async_callback("Error reading response headers from APNS server");
				connection = nil;
				return;
			end
		until not non_final_status(headers:get(":status"))
		
		-- close stream and check response
		local body, err, errno = stream:get_body_as_string();
		stream:shutdown();
		if body == nil then
			module:log("error", "APNS get_body_as_string error %s: %s", tostring(errno or ce.EPIPE), tostring(err or ce.strerror(ce.EPIPE)));
			async_callback("Error reading response body from APNS server");
			connection = nil;
			return;
		end
		local status = headers:get(":status");
		local response = json.decode(body);
		module:log("debug", "APNS response body(%s): %s", tostring(status), tostring(body));
		module:log("debug", "Decoded APNS response body(%s): %s", tostring(status), pretty.write(response));
		if status == "200" then
			async_callback(false);
			return;
		end
		
		-- process returned errors
		module:log("info", "APNS error response %s: %s", tostring(status), tostring(response["reason"]));
		async_callback(string.format("APNS error response %s: %s", tostring(status), tostring(response["reason"])));
		if
		(status == "400" and response["reason"] == "BadDeviceToken") or
		(status == "400" and response["reason"] == "DeviceTokenNotForTopic") or
		(status == "410" and response["reason"] == "Unregistered")
		then
			unregister_token(settings["token"]);
		end
		
		-- try again on idle timeout
		if status == "400" and response["reason"] == "IdleTimeout" then
			connection = nil;
			return module:fire_event("incoming-push-to-apns", event);
		end
	end);
	
	return true;		-- signal the use of use async iq responses
end

-- setup
certstring = readAll(apns_cert);
keystring = readAll(apns_key);
module:hook("incoming-push-to-apns", apns_handler);
module:log("info", "Appserver APNS submodule loaded");
function module.unload()
	if module.unhook then
		module:unhook("incoming-push-to-apns", apns_handler);
	end
	module:log("info", "Appserver APNS submodule unloaded");
end
