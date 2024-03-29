-- mod_push_appserver
--
-- Copyright (C) 2017-2020 Thilo Molitor
--
-- This file is MIT/X11 licensed.
--
-- Implementation of a simple push app server
--

-- depends
module:depends("http");
module:depends("disco");

-- imports
package.path = module:get_directory().."/?.lua;"..package.path;		-- add module path to lua search path (needed for pl)
local appserver_global = module:shared("*/push_appserver/appserver_global");
if not appserver_global.pretty then appserver_global.pretty = require("pl.pretty"); end
local os = require "os";
local http = require "net.http";
local hashes = require "util.hashes";
local datetime = require "util.datetime";
local st = require "util.stanza";
local dataform = require "util.dataforms".new;
local have_id, id = pcall(require, "util.id"); -- Only available in 0.10+
local uuid = require "util.uuid".generate;
if have_id then
	uuid = id.medium;
end
local t = require "util.throttle"
local string = string;
local zthrottle = module:require "zthrottle";

-- configuration
local body_size_limit = 4096; -- 4 KB
local store_module_name = module:get_option_string("push_appserver_store_plugin", "cached");	-- store plugin to use
local store_params = module:get_option("push_appserver_store_params", nil);						-- store params
local debugging = module:get_option_boolean("push_appserver_debugging", false);					-- debugging (should be false on production servers)
-- space out pushes with an interval of 5 seconds ignoring all but the first and last push in this interval (moving the last push to the end of the interval)
-- (try to prevent denial of service attacks and save battery on mobile devices)
zthrottle:set_distance(module:get_option_number("push_appserver_rate_limit", 5));

--- sanity
local parser_body_limit = module:context("*"):get_option_number("http_max_content_size", 10*1024*1024);
if body_size_limit > parser_body_limit then
	module:log("warn", "%s_body_size_limit exceeds HTTP parser limit on body size, capping file size to %d B", module.name, parser_body_limit);
	body_size_limit = parser_body_limit;
end

-- namespace
local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_push = "urn:xmpp:push:0";

local push_store = (module:require(store_module_name.."_store"))(store_params);

-- html helper
local function html_skeleton()
	local header, footer;
	header = "<!DOCTYPE html>\n<html><head><title>mod_"..module.name.."</title></head><body>\n";
	footer = "\n</body></html>";
	return header, footer;
end

local function get_html_form(...)
	local html = '<form method="post"><table>\n';
	for i,v in ipairs{...} do
		html = html..'<tr><td>'..tostring(v)..'</td><td><input type="text" name="'..tostring(v)..'" required></td></tr>\n';
	end
	html = html..'<tr><td>&nbsp;</td><td><button type="submit">send request</button></td></tr>\n</table></form>';
	return html;
end

-- internal functions
local function register_node(arguments)
	-- if we already know this node and push type combination just use the old secret to provide a more stable api
	local settings = push_store:get(arguments["node"]);
	if settings["type"] == arguments["type"] then
		module:log("info", "Re-registered push device (%s)",
			settings["token"] == arguments["token"] and "same token" or "token changed");
		settings["token"] = arguments["token"];
		settings["renewed"] = datetime.datetime();
		module:log("debug", "settings: %s", appserver_global.pretty.write(settings));
		push_store:set(arguments["node"], settings);
		return settings;
	end
	
	-- store this new token-node combination
	settings["type"]       = arguments["type"];
	settings["node"]       = arguments["node"];
	settings["secret"]     = hashes.hmac_sha256(arguments["type"]..":"..arguments["token"].."@"..arguments["node"], os.clock(), true);
	settings["token"]      = arguments["token"];
	settings["registered"] = datetime.datetime();
	module:log("debug", "settings: %s", appserver_global.pretty.write(settings));
	push_store:set(arguments["node"], settings);
	return settings;
end

-- hooks
local function sendError(origin, stanza, text)
	module:log("info", "Replying with {cancel, item-not-found} error: "..tostring(text));
	origin.send(st.error_reply(stanza, "cancel", "item-not-found", text));
	return true;
end

local function sendCommandError(origin, stanza)
	origin.send(st.error_reply(stanza, "modify", "not-acceptable", "Unknown command data"));
	return true;
end

local register_form = dataform {
	{ name = "type"; type = "hidden"; required = true; };
	{ name = "node"; type = "hidden"; required = true; };
	{ name = "token"; type = "hidden"; required = true; };
};

local register_result_form = dataform {
	{ name = "jid"; type = "jid-single"; };
	{ name = "node"; type = "text-single"; };
	{ name = "secret"; type = "text-single"; };
};

local function registerPush(stanza, origin)
	local commandNode = stanza:find("{http://jabber.org/protocol/commands}command");
	if not commandNode then return; end
	
	-- extract command (only executing v1-register-push is supported)
	local command = commandNode.attr.node;
	local action = commandNode.attr.action;
	if command ~= "v1-register-push" or action ~= "execute" then return; end
	
	-- extract data
	local dataNode = commandNode:find("{jabber:x:data}");
	if not dataNode then return; end
	local data, errors = register_form:data(dataNode);
	if errors then return sendCommandError(origin, stanza); end
	if not data["type"] or not data["node"] or not data["token"] then
		sendCommandError(origin, stanza);
	end
	
	-- register node
	local settings = register_node(data);
	if not settings then return sendCommandError(origin, stanza); end
	
	-- send command reply with sessionid set to uuid()
	local reply = st.reply(stanza);
	local form_data = { jid = module:get_host(); node = settings["node"]; secret = settings["secret"] };
	reply:tag("command", {
		sessionid = uuid();
		node = "v1-register-push";
		status = "complete";
		xmlns = "http://jabber.org/protocol/commands";
	}):add_child(register_result_form:form(form_data));
	origin.send(reply);
	
	return true;
end

local unregister_form = dataform {
	{ name = "type"; type = "hidden"; required = true; };
	{ name = "node"; type = "hidden"; required = true; };
};

local unregister_result_form = dataform {
	{ name = "jid"; type = "jid-single"; };
	{ name = "node"; type = "text-single"; };
};

local function unregisterPush(stanza, origin)
	local commandNode = stanza:find("{http://jabber.org/protocol/commands}command");
	if not commandNode then return; end
	
	-- extract command (only executing v1-unregister-push is supported)
	local command = commandNode.attr.node;
	local action = commandNode.attr.action;
	if command ~= "v1-unregister-push" or action ~= "execute" then return; end
	
	-- extract data
	local dataNode = commandNode:find("{jabber:x:data}");
	if not dataNode then return; end
	local data, errors = unregister_form:data(dataNode);
	if errors then return sendCommandError(origin, stanza); end
	if not data["type"] or not data["node"] or not data["token"] then
		sendCommandError(origin, stanza);
	end
	
	-- register node
	local retval = unregister_push_node(data["node"], data["type"]);
	if not retval then return sendCommandError(origin, stanza); end
	
	-- send command reply with sessionid set to uuid()
	local reply = st.reply(stanza);
	local form_data = { jid = module:get_host(); node = data["node"] };
	reply:tag("command", {
		sessionid = uuid();
		node = "v1-unregister-push";
		status = "complete";
		xmlns = "http://jabber.org/protocol/commands";
	}):add_child(unregister_result_form:form(form_data));
	origin.send(reply);
	
	return true;
end

local function handleCommand(stanza, origin)
	local commandNode = stanza:find("{http://jabber.org/protocol/commands}command");
	if not commandNode then return; end
	local dataNode = commandNode:find("{jabber:x:data}");
	if not dataNode then return; end
	
	-- extract command (only executing v1-register-push and v1-unregister-push is supported)
	local command = commandNode.attr.node;
	local action = commandNode.attr.action;
	if action ~= "execute" then return; end
	if command ~= "v1-register-push" then return registerPush(stanza, origin); end;
	if command ~= "v1-unregister-push" then return unregisterPush(stanza, origin); end;
	return;
end

local summary_form = dataform {
	{ name = "FORM_TYPE"; type = "hidden"; value = "urn:xmpp:push:summary"; };
	{ name = "message-count"; type = "text-single"; };
	{ name = "pending-subscription-count"; type = "text-single"; };
	{ name = "last-message-sender"; type = "jid-single"; };
	{ name = "last-message-body"; type = "text-single"; };
};

local options_form = dataform {
	{ name = "FORM_TYPE"; value = xmlns_pubsub.."#publish-options"; };
	{ name = "secret"; type = "hidden"; required = true; };
};

module:hook("iq/host", function(event)
	local stanza, origin = event.stanza, event.origin;
	
	-- handle register/unregister commands
	if stanza:find("{http://jabber.org/protocol/commands}command") then
		return handleCommand(stanza, origin);
	end
	
	-- handle push:
	local publishNode = stanza:find("{"..xmlns_pubsub.."}/publish");
	if not publishNode then return; end
	-- only handle real pushes and let mod_pubsub handle all other cases
	if not publishNode:find("item/{"..xmlns_push.."}notification") then return; end
	-- extract summary if given
	local summaryNode = publishNode:find("item/{"..xmlns_push.."}notification/{jabber:x:data}");
	local summary, errors;
	if summaryNode then
		summary, errors = summary_form:data(summaryNode);
		if errors then return sendError(origin, stanza, "Error decoding push summary node"); end
	end
	
	-- push options and the secret therein are mandatory
	local optionsNode = stanza:find("{"..xmlns_pubsub.."}/publish-options/{jabber:x:data}");
	if not optionsNode then return sendError(origin, stanza, "Error extracting options node"); end
	local data, errors = options_form:data(optionsNode);
	if errors then return sendError(origin, stanza, "Error decoding options node"); end
	
	local node = publishNode.attr.node;
	local secret = data["secret"];
	if not node or not secret then return sendError(origin, stanza, "Node and/or secret missing"); end
	
	local settings = push_store:get(node);
	if not settings or secret ~= settings["secret"] then return sendError(origin, stanza, "Unknown node or secret"); end
	
	-- callback to handle synchronous and asynchronous iq responses
	local async_callback = function(success)
		if success or success == nil then
			module:log("error", "Push handler for type '%s' not executed successfully%s", settings["type"], type(success) == "string" and ": "..success or ": handler not found");
			origin.send(st.error_reply(stanza, "wait", "internal-server-error", type(success) == "string" and success or "Internal error in push handler"));
			settings["last_push_error"] = datetime.datetime();
		else
			origin.send(st.reply(stanza));
			settings["last_successful_push"] = datetime.datetime();
		end
		push_store:set(node, settings);
	end
	
	-- throttling
	local event = {async_callback = async_callback, origin = origin, settings = settings, summary = summary, stanza = stanza};
	local handler_push_priority = tostring(module:fire_event("determine-"..settings["type"].."-priority", event));
	local zthrottle_id = handler_push_priority.."@"..settings["node"];
	local ztrottle_retval = zthrottle:incoming(zthrottle_id, function()
		module:log("info", "Firing event '%s' (node = '%s', secret = '%s')", "incoming-push-to-"..settings["type"], settings["node"], settings["secret"]);
		local success = module:fire_event("incoming-push-to-"..settings["type"], event);
		-- true indicates handling via async_callback, everything else is synchronous and must be handled directly
		if not (type(success) == "boolean" and success) then async_callback(success); end
	end);
	if ztrottle_retval == "ignored" then
		module:log("info", "Rate limit for node '%s' reached, ignoring push request (and returning 'wait' error)", settings["node"]);
		origin.send(st.error_reply(stanza, "wait", "resource-constraint", "Ratelimit reached"));
		return true;
	end
	return true;
end);

local function unregister_push_node(node, type)
	local settings = push_store:get(node);
	if settings["type"] == type then
		push_store:set(node, nil);
		module:log("info", "Unregistered push device, returning: 'OK', '%s', '%s'", tostring(node), tostring(settings["secret"]));
		module:log("debug", "settings were: %s", appserver_global.pretty.write(settings));
		return "OK\n"..node.."\n"..settings["secret"];
	end
	
	module:log("info", "Node not found in unregister, returning: 'ERROR', 'Node not found!'", tostring(node));
	return "ERROR\nNode not found!";
end

module:hook("unregister-push-token", function(event)
	local token, type, timestamp = event.token, event.type, event.timestamp or os.time();
	local node = push_store:token2node(token);
	if node then
		local settings = push_store:get(node);
		local register_timestamp = datetime.parse(settings["renewed"] or settings["registered"]);
		if not timestamp or not register_timestamp or timestamp > register_timestamp then
			return unregister_push_node(node, type);
		else
			module:log("warn", "Unregister via token failed: node '%s' was re-registered after delete timestamp %s", node, datetime.datetime(timestamp));
		end
	else
		module:log("warn", "Unregister via token failed: could not find '%s' node for push token '%s'", type, token);
	end
	return false;
end);

-- http service
local function serve_hello(event, path)
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."<h1>Hello from mod_"..module.name.."!</h1>"..footer;
end

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
	
	local settings = register_node(arguments);
	if not settings then return 400; end
	
	module:log("info", "Registered push device, returning: 'OK', '%s', '%s'", tostring(arguments["node"]), tostring(settings["secret"]));
	return "OK\n"..arguments["node"].."\n"..settings["secret"];
end

local function serve_register_form_v1(event, path)
	if not debugging then return 403; end
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."<h1>Register Push Node</h1>"..get_html_form("type", "node", "token")..footer;
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
	
	return unregister_push_node(arguments["node"], arguments["type"]);
end

local function serve_unregister_form_v1(event, path)
	if not debugging then return 403; end
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."<h1>Unregister Push Node</h1>"..get_html_form("type", "node")..footer;
end

local function serve_push_v1(event, path)
	if #event.request.body > body_size_limit then
		module:log("warn", "Post body too large: %d bytes", #event.request.body);
		return 400;
	end
	
	local arguments = http.formdecode(event.request.body);
	if not arguments["node"] or not arguments["secret"] then
		module:log("warn", "Post data contains unexpected contents");
		return 400;
	end
	
	local node, secret = arguments["node"], arguments["secret"];
	local settings = push_store:get(node);
	if not settings or secret ~= settings["secret"] then
		module:log("info", "Node or secret not found in push, returning: 'ERROR', 'Node or secret not found!'", tostring(node));
		return "ERROR\nNode or secret not found!";
	end
	
	local async_callback = function(success)
		if success or success == nil then
			module:log("warn", "Push handler for type '%s' not executed successfully%s", settings["type"], type(success) == "string" and ": "..success or ": handler not found");
			settings["last_push_error"] = datetime.datetime();
			event.response:send("ERROR\n"..(type(success) == "string" and success or "Internal error in push handler"));
		else
			settings["last_successful_push"] = datetime.datetime();
			event.response:send("OK\n"..node);
		end
		push_store:set(node, settings);
	end
	
	-- throttling
	local event = {async_callback = async_callback, settings = settings};
	local handler_push_priority = tostring(module:fire_event("determine-"..settings["type"].."-priority", event));
	local zthrottle_id = handler_push_priority.."@"..node;
	local ztrottle_retval = zthrottle:incoming(zthrottle_id, function()
		module:log("info", "Firing event '%s' (node = '%s', secret = '%s')", "incoming-push-to-"..settings["type"], node, settings["secret"]);
		local success = module:fire_event("incoming-push-to-"..settings["type"], event);
		-- true indicates handling via async_callback, everything else is synchronous and must be handled directly
		if not (type(success) == "boolean" and success) then async_callback(success); end
	end);
	if ztrottle_retval == "ignored" then
		module:log("warn", "Rate limit for node '%s' reached, ignoring push request (and returning error 'Ratelimit reached')", node);
		return "ERROR\nRatelimit reached!";
	end
	
	return true;		-- keep connection open until async_callback is called
end

local function serve_push_form_v1(event, path)
	if not debugging then return 403; end
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."<h1>Send Push Request</h1>"..get_html_form("node", "secret")..footer;
end

local function serve_settings_v1(event, path)
	if not debugging then return 403; end
	local output, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	if not path or path == "" then
		output = output.."<h1>List of devices (node uuids)</h1>";
		for node in push_store:list() do
			output = output .. '<a href="'..(not path and "settings/" or "")..node..'">'..node.."</a><br>\n";
		end
		return output.."</body></html>";
	end
	path = path:match("^([^/]+).*$");
	local settings = push_store:get(path);
	return output..'<a href="../settings">Back to List</a><br>\n<pre>'..appserver_global.pretty.write(settings).."</pre>"..footer;
end

local function serve_health_v1(event, path)
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."RUNNING"..footer;
end

module:provides("http", {
	route = {
		["GET"] = serve_hello;
		["GET /"] = serve_hello;
		["GET /v1/register"] = serve_register_form_v1;
		["GET /v1/register/*"] = serve_register_form_v1;
		["POST /v1/register"] = serve_register_v1;
		["GET /v1/unregister"] = serve_unregister_form_v1;
		["GET /v1/unregister/*"] = serve_unregister_form_v1;
		["POST /v1/unregister"] = serve_unregister_v1;
		["GET /v1/push"] = serve_push_form_v1;
		["GET /v1/push/*"] = serve_push_form_v1;
		["POST /v1/push"] = serve_push_v1;
		["GET /v1/settings"] = serve_settings_v1;
		["GET /v1/settings/*"] = serve_settings_v1;
		["GET /v1/health"] = serve_health_v1;
	};
});

if debugging then
	module:log("warn", "Debugging is activated, you should turn this off on production servers for security reasons!!!");
	module:log("warn", "Setting: 'push_appserver_debugging'.");
end
module:log("info", "Appserver started at URL: <%s>", module:http_url().."/");
