-- mod_push_appserver_apns
--
-- Copyright (C) 2017 Thilo Molitor
--
-- This file is MIT/X11 licensed.
--
-- Submodule implementing APNS communication
--

-- imports
local socket = require "socket";
local ssl = require "ssl";
local string = require "string";
local t_remove = table.remove;
local datetime = require "util.datetime";
local hashes = require "util.hashes";

-- this is the master module
module:depends("push_appserver");

-- configuration
local test_environment = false;
local apns_cert = module:get_option_string("push_appserver_apns_cert", nil);					--push certificate (no default)
local apns_key = module:get_option_string("push_appserver_apns_key", nil);						--push certificate key (no default)
local capath = module:get_option_string("push_appserver_apns_capath", "/etc/ssl/certs");		--ca path on debian systems
local ciphers = module:get_option_string("push_appserver_apns_ciphers",
	"ECDHE-RSA-AES256-GCM-SHA384:"..
	"ECDHE-ECDSA-AES256-GCM-SHA384:"..
	"ECDHE-RSA-AES128-GCM-SHA256:"..
	"ECDHE-ECDSA-AES128-GCM-SHA256:"..
	"AES256-SHA"	-- apparently this is needed for the old binary apns endpoint
);	--supported ciphers
local mutable_content = module:get_option_boolean("push_appserver_apns_mutable_content", true);	--flag high prio pushes as mutable content
local push_ttl = module:get_option_number("push_appserver_apns_push_ttl", nil);					--no ttl
local push_priority = module:get_option_string("push_appserver_apns_push_priority", "auto");	--automatically decide push priority
local sandbox = module:get_option_boolean("push_appserver_apns_sandbox", true);					--use APNS sandbox
local feedback_request_interval = module:get_option_number("push_appserver_apns_feedback_request_interval", 3600*24);	--24 hours
local push_host = sandbox and "gateway.sandbox.push.apple.com" or "gateway.push.apple.com";
local push_port = 2195;
local feedback_host = sandbox and "feedback.sandbox.push.apple.com" or "feedback.push.apple.com";
local feedback_port = 2196;
if test_environment then push_host = "localhost"; end

-- global state
local conn = nil;
local pending_pushes = {};
local ordered_push_ids = {};

-- general utility functions
local function stoppable_timer(delay, callback)		-- this function is needed for compatibility with prosody <= 0.10
	local stopped = false;
	local timer = module:add_timer(delay, function(t)
		if stopped then return; end
		return callback(t);
	end);
	if timer and timer["stop"] then return timer; end
	return {
		stop = function () stopped = true end;
		timer;
	};
end

-- small helper function to return new table with only "maximum" elements containing only the newest entries
local function reduce_table(table, maximum)
	local count = 0;
	local result = {};
	for key, value in orderedPairs(table) do
		count = count + 1;
		if count > maximum then break end
		result[key] = value;
	end
	return result;
end

-- utility functions for binary manipulations
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
	return hex2bin(string.format('%08X', long));
end
local function bin2long(bin)
	return tonumber(bin2hex(string.sub(bin, 1, 4)), 16);
end

-- protocol helpers (using latest binary format, not the legacy binary format or the new http/2 format)
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
	local id = string.upper(string.sub(hashes.hmac_sha256(tostring(payload).."@"..tostring(token), os.clock(), true), -8));	-- 8 hex chars (4 bytes)
	local frame = pack_item("token",		token)..
				  pack_item("payload",		payload)..
				  pack_item("identifier",	id)..
				  (ttl and pack_item("ttl", ttl) or "")..		-- ttl is optional
				  pack_item("priority",		priority);			-- priority is optional (default: silent)
	local command = byte2bin(2);	-- notify via latest binary protocol
	local frame_length = long2bin(string.len(frame));
	module:log("debug", "Frame ID: %s", tostring(id));
	module:log("debug", "Frame length: %d (%s)", string.len(frame), tostring(bin2hex(frame_length)));
	module:log("debug", "Frame data: %s", tostring(bin2hex(frame)));
	frame = command..frame_length..frame;
	module:log("debug", "Frame: %s", tostring(bin2hex(frame)));
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
		verify = {"peer", "fail_if_no_peer_cert"},
		capath = capath,
		ciphers = ciphers,
		certificate = apns_cert,
		key = apns_key,
		options = {
			"no_sslv2",
			"no_sslv3",
			"no_ticket",
			"no_compression",
			"single_dh_use",
			"single_ecdh_use",
		},
	}
	if test_environment then params["verify"] = nil; end
	local success, err;
	
	if conn then success, err = conn:receive(0); end
	--module:log("debug", "conn=%s,success=%s, err=%s", tostring(conn), tostring(success), tostring(err));
	if conn and (err == "timeout" or err == "wantread" or err == nil) then module:log("debug", "already connected to apns: %s", tostring(err)); return conn; end		-- already connected
	
	-- init connection
	module:log("debug", "connecting to %s on port %d", host, port);
	conn, err = socket.tcp();
	if not conn then module:log("error", "Could not create APNS socket: %s", tostring(err)); return nil; end
	success, err = conn:connect(host, port);
	if not success then module:log("error", "Could not connect APNS socket: %s", tostring(err)); return nil; end
	
	-- init tls and timeouts
	conn, err = ssl.wrap(conn, params);
	if not conn then module:log("error", "Could not tls-wrap APNS socket: %s", tostring(err)); return nil; end
	success, err = conn:dohandshake();
	if not success then module:log("error", "Could not negotiate TLS encryption with APNS: %s", tostring(err)); return nil; end
	conn:settimeout(0);		-- zero timeout allows for a maximum of pushes per second
	
	module:log("debug", "connection established successfully");
	return conn;
end
local function close_connection(conn)
	if conn then conn:close(); end
	return nil;
end
local function sleep(sec)
    socket.select(nil, nil, sec)
end
local function receive_error()
	local error_frame, err = conn:receive(6);
	if err == "timeout" or err == "wantread" then return false; end		-- no error occured yet
	if err then
		module:log("info", "Could not receive data from APNS socket: %s", tostring(err));
		return true;
	end
	local status, error_id = extract_error(error_frame);
	module:log("info", "Got error for ID '%s': %s", tostring(error_id), tostring(status));
	-- call receive_error() again to wait for pending socket close (apns closes the socket immediately after sending the error frame)
	while not receive_error() do sleep(0.01); end
	return error_id, status;
end

-- handlers
local function apns_handler(event)
	local settings = event.settings;
	local summary = event.summary;
	local async_callback = event.async_callback;
	
	-- prepare data to send (using latest binary format, not the legacy binary format or the new http/2 format)
	local payload;
	local priority = push_priority;
	if push_priority == "auto" then
		priority = (summary and summary["last-message-body"] ~= nil) and "high" or "silent";
	end
	if priority == "high" then
		payload = '{"aps":{'..(mutable_content and '"mutable-content":"1",' or '')..'"alert":["title": "dummy", "body": "dummy"],"sound":"default"}}';
	else
		payload = '{"aps":{"content-available":1}}';
	end
	local frame, id = create_frame(settings["token"], payload, push_ttl, priority);
	
	conn = init_connection(conn, push_host, push_port);
	if not conn then return "Error connecting to APNS"; end		-- error occured
	
	-- register timer (use 2 seconds delay for timeout)
	-- NOTE:
	-- APNS pushes are pipelined. If one push triggers an error, APNS returns an error frame and closes the connection.
	-- All pushes pipelined *after* the unsuccessful push are lost and have to be retried.
	-- All pushes pipelined *before* the unsuccessful push where successful.
	pending_pushes[id] = {event = event, timer = stoppable_timer(2, function()
		local error, status = receive_error(0);		-- don't wait, just try to receive already pending errors
		local repush = {};
		if type(error) == "boolean" and not error then		-- no error
			module:log("debug", "Cleaning up successful push ID %s (timer triggered)...", tostring(id));
			pending_pushes[id]["timer"]:stop();
			pending_pushes[id]["event"].async_callback(false);		-- timeout --> no error occured
			pending_pushes[id] = nil;
			-- remove this id from odered_push_ids table, too
			for i, push_id in ipairs(ordered_push_ids) do
				if push_id == id then table.remove(ordered_push_ids, i); break; end
			end
		elseif type(error) == "boolean" and error then		-- read error
			module:log("warn", "APNS read error --> resending *all* pending pushes...");
			repush = pending_pushes;		-- resend all
			-- stop all timers (we need new ones for resending pushes)
			for push_id, push_table in pairs(pending_pushes) do
				push_table["timer"]:stop();
			end
			-- clear all pending pushes
			pending_pushes = {};
			ordered_push_ids = {};
		elseif type(error) ~= "boolean" then				-- error frame (error contains push id)
			module:log("warn", "APNS push error for ID '%s' --> resending all following pushes...", error);
			local error_id_found = false;
			for i, push_id in ipairs(ordered_push_ids) do
				module:log("debug", "Queue entry %d: %s", i, tostring(push_id))
				pending_pushes[push_id]["timer"]:stop();	-- stop all timers (we need new ones for resending pushes)
				if push_id == error then			-- this push had an error
					error_id_found = true;
					pending_pushes[push_id]["event"].async_callback("APNS error: "..tostring(status));	-- --> an error occured
				elseif not error_id_found then		-- every push *before* this error was successfull
					module:log("debug", "Cleaning up successful push ID %s (error triggered)...", tostring(push_id));
					pending_pushes[push_id]["event"].async_callback(false);		-- --> no error occured
				else							-- every push *after* this error has to be resent
					repush[push_id] = pending_pushes[push_id];		-- add to resend queue
				end
			end
			-- clear all pending pushes
			pending_pushes = {};
			ordered_push_ids = {};
		end
		-- resend queued pushes after 100ms delay
		stoppable_timer(0.1, function()
			for push_id, push_table in pairs(repush) do
				local retval = apns_handler(push_table["event"]);
				if type(retval) ~= "boolean" or not retval then
					push_table["event"].async_callback("REpush error: "..tostring(retval));		-- --> a synchronous error occured
				end
			end
		end)
	end)};
	table.insert(ordered_push_ids, id)
	
	-- send frame
	module:log("debug", "sending out frame with id '%s'...", id);
	local success, err = conn:send(frame);
	if success ~= string.len(frame) then
		module:log("warn", "Could not send data to APNS socket: %s (will retry in timer)", tostring(err));
	end
	
	return true;		-- signal the use of use async iq responses
end

-- timers
local function query_feedback_service()
	local conn;
	module:log("info", "Connecting to APNS feedback service");
	conn = init_connection(nil, feedback_host, feedback_port, 8);	-- use 8 second read timeout
	if not conn then	-- error occured
		return feedback_request_interval;		-- run timer again
	end
	
	repeat
		local feedback, err = conn:receive(6);
		if err == "timeout" or err == "closed" then		-- no error occured (no data left)
			module:log("info", "No more APNS errors left on feedback service");
			break;
		end
		if err then
			module:log("error", "Could not receive data from APNS feedback socket (receive 1): %s", tostring(err));
			break;
		end
		local timestamp = bin2long(string.sub(feedback, 1, 4));
		local token_length = bin2short(string.sub(feedback, 5, 6));
		
		feedback, err = conn:receive(token_length);
		if err then		-- timeout is also an error here, since the frame is incomplete in this case
			module:log("error", "Could not receive data from APNS feedback socket (receive 2): %s", tostring(err));
			break;
		end
		local token = bin2hex(string.sub(feedback, 1, token_length));
		module:log("info", "Got feedback service entry for token '%s' timestamped with '%s", token, datetime.datetime(timestamp));
		
		if not module:fire_event("unregister-push-token", {token = token, type = "apns", timestamp = timestamp}) then
			module:log("warn", "Could not unregister push token");
		end
	until false;
	close_connection(conn);
	return feedback_request_interval;		-- run timer again
end

-- setup
module:hook("incoming-push-to-apns", apns_handler);
module:add_timer(feedback_request_interval, query_feedback_service);
module:log("info", "Appserver APNS submodule loaded");
query_feedback_service();	-- query feedback service directly after module load
function module.unload()
	if module.unhook then
		module:unhook("incoming-push-to-apns", apns_handler);
	end
	module:log("info", "Appserver APNS submodule unloaded");
end
