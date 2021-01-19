-- mod_push_appserver_apns
--
-- Copyright (C) 2017-2020 Thilo Molitor
--
-- This file is MIT/X11 licensed.
--
-- Submodule implementing APNS communication
--

-- this is the master module
module:depends("push_appserver");

-- imports
local appserver_global = module:shared("*/push_appserver/appserver_global");
local cq = require "net.cqueues".cq;
local promise = require "cqueues.promise";
local http_client = require "http.client";
local new_headers = require "http.headers".new;
local ce = require "cqueues.errno";
local openssl_ctx = require "openssl.ssl.context";
local x509 = require "openssl.x509";
local pkey = require "openssl.pkey";
local json = require "util.json";

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
local collapse_pushes = module:get_option_boolean("push_appserver_apns_collapse_pushes", false);		--collapse pushes into one
local push_host = sandbox and "api.sandbox.push.apple.com" or "api.push.apple.com";
local push_port = 443;
if test_environment then push_host = "localhost"; end
local default_tls_options = openssl_ctx.OP_NO_COMPRESSION + openssl_ctx.OP_SINGLE_ECDH_USE + openssl_ctx.OP_NO_SSLv2 + openssl_ctx.OP_NO_SSLv3;

-- check config
assert(apns_cert ~= nil, "You need to set 'push_appserver_apns_cert'")
assert(apns_key ~= nil, "You need to set 'push_appserver_apns_key'")
assert(topic ~= nil, "You need to set 'push_appserver_apns_topic'")

-- global state
local connection_promise = nil;
local cleanup_controller = nil
local certstring = "";
local keystring  = "";

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
	end);
end
local function close_connection()
	-- reset promise to start a new connection
	local p = connection_promise;
	connection_promise = nil;
	
	-- ignore errors in here
	if p then
		local ok, errobj = pcall(function()
			local stream, err, errno, ok;
			-- this waits for the resolution of the OLD promise and either returns the connection object or throws an error
			-- (which will be caught by the wrapping pcall)
			local connection = p:get();
			
			-- close OLD connection
			connection.goaway_handler = nil;
			connection:close();
		end);
	end
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
	
	local function retry()
		close_connection();
		module:add_timer(1, function()
			module:fire_event("incoming-push-to-apns", event);
		end);
	end
	
	cq:wrap(function()
		-- create new tls context and connection if not already connected
		-- this uses a cqueues promise to make sure we're not connecting twice
		if connection_promise == nil then
			connection_promise = promise.new();
			module:log("info", "Creating new connection to APNS server '%s:%s'...", push_host, tostring(push_port));
			
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
			
			-- create new connection and log possible errors
			local connection, err, errno = http_client.connect({
				host = push_host;
				port = push_port;
				tls = true;
				version = 2;
				ctx = ctx;
			});
			if connection == nil then
				module:log("error", "APNS connect error %s: %s", tostring(errno), tostring(err));
				connection_promise:set(false, {error = err, errno = errno});
			else
				-- close connection on GOAWAY frame
				module:log("info", "connection established, waiting for GOAWAY frame in extra cqueue function...");
				connection.goaway_handler = cq:wrap(function()
					while connection.goaway_handler do
						if connection.recv_goaway:wait() then
							module:log("info", "received GOAWAY frame, closing connection...");
							connection.goaway_handler = nil;
							connection:close();
							return;
						end
					end
				end);
				connection_promise:set(true, connection);
			end
		end
		
		-- wait for connection establishment before continuing by waiting for the connection promise which wraps the connection object
		local ok, errobj = pcall(function()
			local stream, err, errno, ok;
			-- this waits for the resolution of the promise and either returns the connection object or throws an error
			-- (which will be caught by the wrapping pcall)
			local connection = connection_promise:get();
			
			if connection.recv_goaway_lowest then		-- check for goaway (is there any api method for this??)
				module:log("error", "reconnecting because we received a GOAWAY frame: %s", tostring(connection.recv_goaway_lowest));
				return retry();
			end
				
			-- create new stream for our request
			module:log("debug", "Creating new http/2 stream...");
			stream, err, errno = connection:new_stream();
			if stream == nil then
				module:log("error", "retrying: APNS new_stream error %s: %s", tostring(errno), tostring(err));
				return retry();
			end
			module:log("debug", "New http/2 stream id: %s", stream.id);
			
			-- write request
			module:log("debug", "Writing http/2 request on stream %s...", stream.id);
			local req_headers = new_headers();
			req_headers:upsert(":method", "POST");
			req_headers:upsert(":scheme", "https");
			req_headers:upsert(":path", "/3/device/"..settings["token"]);
			req_headers:upsert("content-length", string.format("%d", #payload));
			module:log("debug", "APNS topic: %s (%s)", tostring(topic), tostring(priority == "voip" and topic..".voip" or topic));
			req_headers:upsert("apns-topic", priority == "voip" and topic..".voip" or topic);
			req_headers:upsert("apns-expiration", tostring(push_ttl));
			local collapse_id = nil;
			if priority == "high" then
				if collapse_pushes then collapse_id = "xmpp-body-push"; end
				module:log("debug", "high: push_type: alert, priority: 10, collapse-id: %s", tostring(collapse_id));
				req_headers:upsert("apns-push-type", "alert");
				req_headers:upsert("apns-priority", "10");
				if collapse_id then req_headers:upsert("apns-collapse-id", collapse_id); end
			elseif priority == "voip" then
				if collapse_pushes then collapse_id = "xmpp-voip-push"; end
				module:log("debug", "voip: push_type: alert, priority: 10, collapse-id: %s", tostring(collapse_id));
				req_headers:upsert("apns-push-type", "alert");
				req_headers:upsert("apns-priority", "10");
				if collapse_id then req_headers:upsert("apns-collapse-id", collapse_id); end
			else
				if collapse_pushes then collapse_id = "xmpp-nobody-push"; end
				module:log("debug", "silent: push_type: background, priority: 5, collapse-id: %s", tostring(collapse_id));
				req_headers:upsert("apns-push-type", "background");
				req_headers:upsert("apns-priority", "5");
				if collapse_id then req_headers:upsert("apns-collapse-id", collapse_id); end
			end
			ok, err, errno = stream:write_headers(req_headers, false, 2);
			if not ok then
				stream:shutdown();
				module:log("error", "retrying stream %s: APNS write_headers error %s: %s", stream.id, tostring(errno), tostring(err));
				return retry();
			end
			module:log("debug", "payload: %s", payload);
			ok, err, errno = stream:write_body_from_string(payload, 2)
			if not ok then
				stream:shutdown();
				module:log("error", "retrying stream %s: APNS write_body_from_string error %s: %s", stream.id, tostring(errno), tostring(err));
				return retry();
			end
			
			-- read response
			module:log("debug", "Reading http/2 response on stream %s:", stream.id);
			local headers;
			-- Skip through 1xx informational headers.
			-- From RFC 7231 Section 6.2: "A user agent MAY ignore unexpected 1xx responses"
			repeat
				module:log("debug", "Reading http/2 headers on stream %s...", stream.id);
				headers, err, errno = stream:get_headers(1);
				if headers == nil then
					stream:shutdown();
					module:log("error", "retrying stream %s: APNS get_headers error %s: %s", stream.id, tostring(errno or ce.EPIPE), tostring(err or ce.strerror(ce.EPIPE)));
					return retry();
				end
			until not non_final_status(headers:get(":status"))
			
			-- close stream and check response
			module:log("debug", "Reading http/2 body on stream %s...", stream.id);
			local body, err, errno = stream:get_body_as_string(1);
			module:log("debug", "All done, shutting down http/2 stream %s...", stream.id);
			stream:shutdown();
			if body == nil then
				module:log("error", "retrying stream %s: APNS get_body_as_string error %s: %s", stream.id, tostring(errno or ce.EPIPE), tostring(err or ce.strerror(ce.EPIPE)));
				return retry();
			end
			local status = headers:get(":status");
			local response = json.decode(body);
			module:log("debug", "APNS response body(%s): %s", tostring(status), tostring(body));
			module:log("debug", "Decoded APNS response body(%s): %s", tostring(status), appserver_global.pretty.write(response));
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
				return retry();
			end
		end);
		
		-- handle connection errors (and other backtraces in the push code)
		if not ok then
			module:log("error", "Catched APNS (connect) error: %s", appserver_global.pretty.write(errobj));
			connection_promise = nil;		--retry connection next time
			async_callback("Error sending APNS request");
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
