-- mod_push_appserver
--
-- Copyright (C) 2017 Thilo Molitor
--
-- This file is MIT/X11 licensed.
--
-- Implementation of a simple push app server used by Monal
--

-- imports
local os = require "os";
local pretty = require "pl.pretty";
local http = require "net.http";
local hashes = require "util.hashes";
local datetime = require "util.datetime";
local st = require "util.stanza";
local dataform = require "util.dataforms".new;
local string = string;

-- config
local body_size_limit = 4096; -- 4 KB
local debugging = module:get_option_boolean("push_appserver_debugging", false);

--- sanity
local parser_body_limit = module:context("*"):get_option_number("http_max_content_size", 10*1024*1024);
if body_size_limit > parser_body_limit then
	module:log("warn", "%s_body_size_limit exceeds HTTP parser limit on body size, capping file size to %d B", module.name, parser_body_limit);
	body_size_limit = parser_body_limit;
end

-- depends
module:depends("http");
module:depends("disco");

-- namespace
local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_push = "urn:xmpp:push:0";

-- For keeping state across reloads while caching reads
local push_store = (function()
	local store = module:open_store();
	local cache = {};
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
		return cache[node], true;
	end
	function api:set(node, data)
		cache[node] = data;
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
end)();


-- hooks
local function sendError(origin, stanza)
	origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Unknown push node/secret"));
	return true;
end

local options_form = dataform {
	{ name = "FORM_TYPE"; value = "http://jabber.org/protocol/pubsub#publish-options"; };
	{ name = "secret"; type = "hidden"; required = true; };
};

module:hook("iq/host", function (event)
	local stanza, origin = event.stanza, event.origin;
	
	local publishNode = stanza:find("{http://jabber.org/protocol/pubsub}/publish");
	if not publishNode then return; end
	local pushNode = publishNode:find("item/{urn:xmpp:push:0}notification");
	if not pushNode then return; end
	
	-- push options and the secret therein are mandatory
	local optionsNode = stanza:find("{http://jabber.org/protocol/pubsub}/publish-options/{jabber:x:data}");
	if not optionsNode then return sendError(origin, stanza); end
	local data, errors = options_form:data(optionsNode);
	if errors then return sendError(origin, stanza); end
	
	local node = publishNode.attr.node;
	local secret = data["secret"];
	module:log("debug", "node: %s, secret: %s", tostring(node), tostring(secret));
	if not node or not secret then return sendError(origin, stanza); end
	
	local settings = push_store:get(node);
	if not settings or not #settings then return sendError(origin, stanza); end
	if secret ~= settings["secret"] then return sendError(origin, stanza); end
	
	module:log("info", "Firing event '%s' (node = '%s', secret = '%s')", "incoming-push-to-"..settings["type"], settings["node"], settings["secret"]);
	local success = module:fire_event("incoming-push-to-"..settings["type"], {origin = origin, settings = settings, stanza = stanza});
	if success or success == nil then
		module:log("error", "Push handler for type '%s' not executed successfully%s", settings["type"], type(success) == "string" and ": "..success or "");
		origin.send(st.error_reply(stanza, "wait", "internal-server-error", type(success) == "string" and success or "Internal error in push handler"));
		settings["last_push_error"] = datetime.datetime();
	else
		origin.send(st.reply(stanza));
		settings["last_successful_push"] = datetime.datetime();
	end
	push_store:set(node, settings);
	return true;
end);

-- http service
local function serve_register_v1(event, path)
	if #event.request.body > body_size_limit then
		module:log("warn", "Post body too large: %d bytes", #event.request.body);
		return 400;
	end
	
	local arguments = http.formdecode(event.request.body);
	if not arguments["type"] or not arguments["node"] or not arguments["token"] then
		module:log("warn", "Post data contains unexpected contents");
		return 400;
	end
	
	local settings = push_store:get(arguments["node"]);
	if settings["type"] == arguments["type"] and settings["token"] == arguments["token"] then
		module:log("info", "Re-registered push device, returning: 'OK', '%s', '%s'", tostring(arguments["node"]), tostring(settings["secret"]));
		module:log("debug", "settings: %s", pretty.write(settings));
		module:log("debug", "arguments: %s", pretty.write(arguments));
		settings["renewed"] = datetime.datetime();
		push_store:set(arguments["node"], settings);
		return "OK\n"..arguments["node"].."\n"..settings["secret"];
	end
	
	-- store this new token-node combination
	settings["type"]       = arguments["type"];
	settings["node"]       = arguments["node"];
	settings["secret"]     = hashes.hmac_sha256(arguments["type"]..":"..arguments["token"].."@"..arguments["node"], os.clock(), true);
	settings["token"]      = arguments["token"];
	settings["registered"] = datetime.datetime();
	push_store:set(arguments["node"], settings);
	
	module:log("info", "Registered push device, returning: 'OK', '%s', '%s'", tostring(arguments["node"]), tostring(settings["secret"]));
	module:log("debug", "arguments: %s", pretty.write(arguments));
	return "OK\n"..arguments["node"].."\n"..settings["secret"];
end

local function serve_unregister_v1(event, path)
	if #event.request.body > body_size_limit then
		module:log("warn", "Post body too large: %d bytes", #event.request.body);
		return 400;
	end
	
	local arguments = http.formdecode(event.request.body);
	if not arguments["type"] or not arguments["node"] then
		module:log("warn", "Post data contains unexpected contents");
		return 400;
	end
	
	local settings = push_store:get(arguments["node"]);
	if settings["type"] == arguments["type"] then
		module:log("info", "Unregistered push device, returning: 'OK', '%s', '%s'", tostring(arguments["node"]), tostring(settings["secret"]));
		module:log("debug", "settings: %s", pretty.write(settings));
		module:log("debug", "arguments: %s", pretty.write(arguments));
		push_store:set(arguments["node"], nil);
		return "OK\n"..arguments["node"].."\n"..settings["secret"];
	end
	
	module:log("info", "Node not found in unregister, returning: 'ERROR', 'Node not found!'", tostring(arguments["node"]));
	return "ERROR\nNode not found!";
end

local function serve_data_v1(event, path)
	if not debugging then return 403; end
	local output = "<!DOCTYPE html>\n<html><head><title>mod_"..module.name.." settings</title></head><body>";
	if not path or path == "" then
		output = output.."<h1>List of devices (node uuids)</h1>";
		for node in push_store:list() do
			output = output .. '<a href="/v1/settings/'..node..'">'..node.."</a>\n";
		end
		return output.."</body></html>";
	end
	local settings = push_store:get(path);
	return pretty.write(settings).."</body></html>";
end

local function serve_hello(event, path)
	event.response.headers.content_type = "text/html;charset=utf-8"
	return "<!DOCTYPE html>\n<html><head></head><body><h1>Hello from mod_"..module.name.."!</h1>\n</body></html>"..tostring(path);
end

module:provides("http", {
	route = {
		["GET"] = serve_hello;
		["GET /"] = serve_hello;
		["POST /v1/register"] = serve_register_v1;
		["POST /v1/unregister"] = serve_unregister_v1;
		["GET /v1/settings"] = serve_data_v1;
		["GET /v1/settings/*"] = serve_data_v1;
	};
});

module:log("info", "Appserver started at URL: <%s>", module:http_url());
