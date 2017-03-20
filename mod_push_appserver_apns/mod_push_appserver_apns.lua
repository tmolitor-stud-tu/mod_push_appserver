-- mod_push_appserver_apns
--
-- Copyright (C) 2017 Thilo Molitor
--
-- This file is MIT/X11 licensed.
--
-- Implementation of a simple push app server
--

-- imports
local socket = require "socket";
local ssl = require "ssl";
local string = require "string";
local t_remove = table.remove;
local datetime = require "util.datetime";

-- this is the master module
module:depends("push_appserver");

-- configuration
local capath = module:get_option_string("push_appserver_apns_capath", "/etc/ssl/certs");		--default: ca path on debian systems
local push_alert = module:get_option_string("push_appserver_apns_push_alert", "dummy");			--dummy alert text
local push_ttl = module:get_option_number("push_appserver_apns_push_ttl", nil);					--default: no ttl
local push_priority = module:get_option_string("push_appserver_apns_push_priority", "HIGH");	--high priority pushes
local sandbox = module:get_option_boolean("push_appserver_apns_sandbox", true);					--default: use APNS sandbox
local feedback_request_interval = module:get_option_number("push_appserver_apns_feedback_request_interval", 3600*24);	--24 hours
local push_host = sandbox and "gateway.sandbox.push.apple.com" or "gateway.push.apple.com";
local push_posrt = 2195;
local feedback_host = sandbox and "feedback.sandbox.push.apple.com" or "feedback.push.apple.com";
local feddback_port = 2196;

-- global state
local conn = nil;
local queue = {};

-- util functions
local function hex2bin(str)
	return (str:gsub('..', function(cc)
		return string.char(tonumber(cc, 16))
	end))
end
local function bin2hex(str)
	return (str:gsub('.', function (c)
		return string.format('%02X', string.byte(c));
	end))
end
local function byte2bin(byte)
	if byte < 0 or byte > 255 then return nil; end
	return string.char(byte);
end
local function bin2byte(bin)
	return string.byte(bin);
end
local function short2bin(short)
	if short < 0 or short > 2^16 - 1 then return nil; end
	return hex2bin(string.format('%04X', short));
end
local function bin2short(bin)
	return tonumber(bin2hex(string.sub(bin, 1, 2)), 16);
end
local function long2bin(long)
	if long < 0 or long > 2^32 - 1 then return nil; end
	return hex2bin(string.format('%04X', long));
end
local function bin2long(bin)
	return tonumber(bin2hex(string.sub(bin, 1, 4)), 16);
end

-- protocol functions (using latest binary format, not legacy binary format or the new http/2 format)
local function pack_item(itemtype, data)
	local id = 0;
	if itemtype == "token" then				-- push token (named deviceid in apple docs)
		id = 1;
		data = hex2bin(data);
	elseif itemtype == "payload" then		-- json encoded payload
		id = 2;
		-- nothing more to do here
	elseif itemtype == "identifier" then	-- notification identifier
		id = 3;
		data = string.sub(hex2bin(data), -4);
	elseif itemtype == "ttl" then			-- expiration date (given as TTL in seconds counted from now on)
		id = 4;
		data = long2bin(os.time() + data);
	elseif itemtype == "priority" then		-- priority (can only be "silent" or "high")
		id = 5;
		data = byte2bin(data == "high" and 10 or 5);	-- default: 5 (silent)
	else
		return nil;
	end
	return byte2bin(id)..short2bin(string.len(data))..data;
end
local function create_frame(token, payload, ttl, priority)
	local id = string.sub(hashes.hmac_sha256(tostring(payload).."@"..tostring(token), os.clock(), true), -8);	-- 8 hex chars (4 bytes)
	local frame = pack_item("token",		token)..
				  pack_item("payload",		payload)..
				  pack_item("identifier",	id)..
				  (ttl and pack_item("ttl", ttl) or "")..		-- ttl is optional
				  pack_item("priority",		priority);
	local command = byte2bin(2);	-- notify via latest binary protocol
	local frame_length = short2bin(string.len(frame));
	frame = command..frame_length..frame;
	
	module:log("debug", "Frame data: %s", tostring(bin2hex(frame)));
	module:log("debug", "Frame ID: %s", tostring(id));
	return frame, id;
end
local function extract_error(error_frame)
	local command = string.byte(string.sub(error_frame, 1, 1));
	local status = string.byte(string.sub(error_frame, 2, 2));
	local id = bin2hex(string.sub(error_frame, 3));
	if command ~= 8 then return nil; end		-- error command is 8
	if     status == 000 then status = "No errors encountered";
	elseif status == 001 then status = "Processing error";
	elseif status == 002 then status = "Missing device token";
	elseif status == 003 then status = "Missing topic";
	elseif status == 004 then status = "Missing payload";
	elseif status == 005 then status = "Invalid token size";
	elseif status == 006 then status = "Invalid topic size";
	elseif status == 007 then status = "Invalid payload size";
	elseif status == 008 then status = "Invalid token";
	elseif status == 010 then status = "Shutdown";
	elseif status == 128 then status = "Protocol error (APNs could not parse the notification)";
	elseif status == 255 then status = "None (unknown)";
	end
	return status, id;
end

-- network functions
local function init_connection(conn, host, port)
	local params = {
		mode = "client",
		protocol = "tlsv1_2",
		verify = "none",
		capath = capath,
		certificate = module:get_directory().."/push.pem",
		key = module:get_directory().."/push.key",
		options = "no_compression",
	}
	local success, err;
	
	if conn then conn:settimeout(0); success, err = conn:receive(0); conn:settimeout(1); end
	if conn and err == "timeout" then module:log("debug", "already connected to apns: %s", tostring(err)); return conn; end		-- already connected
	
	-- init connection
	module:log("debug", "connecting to %s port %d", host, port);
	conn, err = socket.tcp();
	if not conn then module:log("error", "Could not create APNS socket: %s", tostring(err)); return nil; end
	success, err = conn:connect(host, port);
	if not success then module:log("error", "Could not connect APNS socket: %s", tostring(err)); return nil; end
	
	-- init tls and timeouts
	conn, err = ssl.wrap(conn, params);
	if not conn then module:log("error", "Could not tls-wrap APNS socket: %s", tostring(err)); return nil; end
	success, err = conn:dohandshake();
	if not success then module:log("error", "Could not negotiate TLS encryption with APNS: %s", tostring(err)); return nil; end
	conn:settimeout(1);
	
	module:log("debug", "connection established successfully");
	return conn;
end
local function close_connection(conn)
	if conn then conn:close(); end
	return nil;
end
function sleep(sec)
    socket.select(nil, nil, sec)
end

-- handlers
local function apns_handler(event)
	local settings = event.settings;
	
	-- prepare data to send (using latest binary format, not legacy binary format or the new http/2 format)
	local payload;
	if push_priority == "high" then
		payload = '{"aps":{"alert":"'..push_alert..'","sound":"default"}}';
	else
		payload = '{"aps":{"content-available":1}}';
	end
	local frame, id = create_frame(settings["token"], payload, push_ttl, push_priority);
	
	conn = init_connection(conn, push_host, push_port);
	if not conn then return "Error connecting to APNS"; end				-- error occured
	
	-- send frame
	success, err = conn:send(frame);
	if success ~= string.len(frame) then
		module:log("error", "Could not send data to APNS socket: %s", tostring(err));
		return "Error communicating with APNS (send)";
	end
	
	-- get status
	local error_frame, err = conn:receive(6);
	if err == "timeout" then return false; end		-- no error happened
	if err then
		module:log("error", "Could not receive data from APNS socket: %s", tostring(err));
		return "Error communicating with APNS (receive)";
	end
	local status, error_id = extract_error(error_frame);
	module:log("warn", "Got error for id '%s': %s", tostring(error_id), tostring(status));
	return true;
end

-- timers
local function query_feedback_service()
	local conn;
	module:log("info", "Connecting to APNS feedback service");
	conn = init_connection(conn, feedback_host, feedback_port);
	if not conn then	-- error occured
		module:add_timer(feedback_request_interval, query_feedback_service);
		return true;
	end
	
	repeat
		local feedback, err = conn:receive(6);
		if err == "timeout" then break; end		-- no error happened (no data left)
		if err then
			module:log("error", "Could not receive data from APNS feedback socket (receive 1): %s", tostring(err));
			close_connection(conn);
			module:add_timer(feedback_request_interval, query_feedback_service);
			return true;
		end
		local timestamp = bin2long(string.sub(feedback, 1, 4));
		local token_length = bin2short(string.sub(feedback, 5, 6));
		
		feedback, err = conn:receive(token_length);
		if err then		-- timeout is also an error here, since the frame is incomplete in this case
			module:log("error", "Could not receive data from APNS feedback socket (receive 2): %s", tostring(err));
			close_connection(conn);
			module:add_timer(feedback_request_interval, query_feedback_service);
			return true;
		end
		local token = bin2hex(string.sub(feedback, 1, token_length));
		module:log("info", "Got feedback service entry for token '%s' timestamped with '%s", token, datetime.datetime(timestamp));
		
		if not module:trigger("unregister-push-token", {token = token, type = "apns", timestamp = timestamp}) then
			module:log("warn", "Could not unregister push token");
		end
	until false;
	close_connection(conn);
	module:add_timer(feedback_request_interval, query_feedback_service);
	return false;
end

-- setup
module:hook("incoming-push-to-apns", apns_handler);
module:add_timer(feedback_request_interval, query_feedback_service);
module:log("info", "Appserver APNS module loaded");
function module.unload()
	module:unhook("incoming-push-to-apns", apns_handler);
	module:log("info", "Appserver APNS module unloaded");
end
