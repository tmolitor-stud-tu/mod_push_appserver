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
if not appserver_global.tablex then appserver_global.tablex = require("pl.tablex"); end
local os = require "os";
local http = require "net.http";
local datetime = require "util.datetime";
local st = require "util.stanza";
local dataform = require "util.dataforms".new;
local string = string;
local zthrottle = module:require "zthrottle";

-- configuration
local body_size_limit = 4096; -- 4 KB
local tombstone_timeout = module:get_option_number("push_appserver_tombstone_timeout", 86400*90);	-- delete tombstones after this much seconds
local store_module_name = module:get_option_string("push_appserver_store_plugin", "cached");		-- store plugin to use
local store_params = module:get_option("push_appserver_store_params", nil);							-- store params
local debugging = module:get_option_boolean("push_appserver_debugging", false);						-- debugging (should be false on production servers)
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

-- hooks
local function sendError(origin, stanza, text)
	module:log("info", "Replying with {cancel, item-not-found} error: "..tostring(text));
	origin.send(st.error_reply(stanza, "cancel", "item-not-found", text));
	return true;
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
	{ name = "type"; type = "hidden"; required = true; };
	{ name = "token"; type = "hidden"; required = true; };
};

module:hook("iq/host", function(event)
	local stanza, origin = event.stanza, event.origin;
	
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
	
	-- push options and the token and type therein are mandatory
	local optionsNode = stanza:find("{"..xmlns_pubsub.."}/publish-options/{jabber:x:data}");
	if not optionsNode then return sendError(origin, stanza, "Error extracting options node"); end
	local data, errors = options_form:data(optionsNode);
	if errors then return sendError(origin, stanza, "Error decoding options node"); end
	
	local node = publishNode.attr.node;
	if not node or not data["type"] or not data["token"] then return sendError(origin, stanza, "Node and/or type and/or token missing"); end
	
	local settings = push_store:get(node) or { node = node };
	if settings["tombstone"] ~= nil then
		module:log("info", "Tombstoned node: %s", tostring(node));
		return sendError(origin, stanza, "Tombstoned node");
	end
	
	local event_settings = appserver_global.tablex.merge(data, settings)
	
	-- callback to handle synchronous and asynchronous iq responses
	local async_callback = function(success)
		if success or success == nil then
			module:log("error", "Push handler for type '%s' not executed successfully%s", event_data["type"], type(success) == "string" and ": "..success or ": handler not found");
			origin.send(st.error_reply(stanza, "wait", "internal-server-error", type(success) == "string" and success or "Internal error in push handler"));
		else
			origin.send(st.reply(stanza));
		end
		push_store:set(node, settings);
	end
	
	-- throttling
	local event = {async_callback = async_callback, origin = origin, settings = event_settings, summary = summary, stanza = stanza};
	local handler_push_priority = tostring(module:fire_event("determine-"..event_settings["type"].."-priority", event));
	local zthrottle_id = handler_push_priority.."@"..event_settings["node"];
	local ztrottle_retval = zthrottle:incoming(zthrottle_id, function()
		module:log("info", "Firing event '%s' (node = '%s', token = '%s')", "incoming-push-to-"..event_settings["type"], event_settings["node"], event_settings["token"]);
		local success = module:fire_event("incoming-push-to-"..event_settings["type"], event);
		-- true indicates handling via async_callback, everything else is synchronous and must be handled directly
		if not (type(success) == "boolean" and success) then async_callback(success); end
	end);
	if ztrottle_retval == "ignored" then
		module:log("info", "Rate limit for node '%s' reached, ignoring push request (and returning 'wait' error)", event_settings["node"]);
		origin.send(st.error_reply(stanza, "wait", "resource-constraint", "Ratelimit reached"));
		return true;
	end
	return true;
end);

module:hook("unregister-push-node", function(event)
	local node, timestamp = event.node, event.timestamp or os.time();
	if node then
		local settings = push_store:get(node) or { node = node };
		settings["tombstone"] = datetime.datetime(event.timestamp);
		push_store:set(node, settings);
	else
		module:log("warn", "Unregister via node failed: could not find node '%s'", token);
	end
	return false;
end);

module:add_timer(86400, function()
	local current_time = os.time();
	for node in push_store:list() do
		local settings = push_store:get(node);
		if settings["tombstone"] and datetime.parse(settings["tombstone"]) + tombstone_timeout < current_time then
			module:log("info", "Deleting tombstoned node: %s", appserver_global.pretty.write(settings));
			push_store:set(node, nil);
		end
	end
end);

-- http service
local function serve_hello(event, path)
	local header, footer = html_skeleton();
	event.response.headers.content_type = "text/html;charset=utf-8";
	return header.."<h1>Hello from mod_"..module.name.."!</h1>"..footer;
end

local function serve_push_v1(event, path)
	if #event.request.body > body_size_limit then
		module:log("warn", "Post body too large: %d bytes", #event.request.body);
		return 400;
	end
	
	local arguments = http.formdecode(event.request.body);
	if not arguments["node"] or not arguments["type"] or not arguments["token"] then
		module:log("warn", "Post data contains unexpected contents");
		return 400;
	end
	
	local node = arguments["node"];
	local settings = push_store:get(node) or { node = node };
	if settings["tombstone"] ~= nil then
		module:log("info", "Tombstoned node: %s", tostring(node));
		return "ERROR\nTombstoned node";
	end
	
	local event_settings = appserver_global.tablex.merge(data, settings)
	
	local async_callback = function(success)
		if success or success == nil then
			module:log("warn", "Push handler for type '%s' not executed successfully%s", event_settings["type"], type(success) == "string" and ": "..success or ": handler not found");
			event.response:send("ERROR\n"..(type(success) == "string" and success or "Internal error in push handler"));
		else
			event.response:send("OK\n"..node);
		end
		push_store:set(node, settings);
	end
	
	-- throttling
	local event = {async_callback = async_callback, settings = event_settings};
	local handler_push_priority = tostring(module:fire_event("determine-"..event_settings["type"].."-priority", event));
	local zthrottle_id = handler_push_priority.."@"..node;
	local ztrottle_retval = zthrottle:incoming(zthrottle_id, function()
		module:log("info", "Firing event '%s' (node = '%s', token = '%s')", "incoming-push-to-"..event_settings["type"], event_settings["node"], event_settings["token"]);
		local success = module:fire_event("incoming-push-to-"..event_settings["type"], event);
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
	return header.."<h1>Send Push Request</h1>"..get_html_form("node", "type", "token")..footer;
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
