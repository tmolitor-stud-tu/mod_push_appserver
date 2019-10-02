# mod\_push\_appserver

Simple and extendable app server for XMPP push notifications as defined in
[XEP-0357][1].

The app server is implemented as a module for the [Prosody][2] XMPP server.

Currently, only push notifications to Apple's [APNS][3] and Google's [FCM][4]
are implemented, but other push services can easily be added in a separate
module.

## Requirements

- Prosody 0.9 or later.
- Lua 5.1 or 5.2.
- Installed luasec Lua library version 0.5 (Debian package: `lua-sec`) or higher.
 
## Installation

Just check out the repository somewhere and point prosody at this directory
using `plugin_paths` in its main config file.  
For example: `plugin_paths = { "/usr/local/lib/mod_push_appserver" }`.

Then add the submodule you need (for example `mod_push_appserver_apns`
or `mod_push_appserver_fcm`) to global `modules_enabled` or to the enabled
modules of a specific virtual host or component.

See this configuration example for [APNS][3] if you want to load the needed submodule as component:  
**Beware:** SNI is only available in upcoming prosody 0.12/trunk, use the same certificate
for all hosts/components (e.g. wildcard certificate or all SANs in one certificate)
if you must use older prosody versions  and remove the `ssl` part from this example.  
```
Component "push.example.org" "push_appserver_apns"
	push_appserver_debugging = false
	push_appserver_apns_sandbox = false
	push_appserver_apns_cert = "/etc/prosody/apns_voip1.crt"
	push_appserver_apns_key = "/etc/prosody/apns_voip1.key"
	ssl = {
		key = "/etc/prosody/certs/push.example.org.key";
		certificate = "/etc/prosody/certs/push.example.org.crt";
	}

Component "push2.example.org" "push_appserver_apns"
	push_appserver_debugging = false
	push_appserver_apns_sandbox = false
	push_appserver_apns_cert = "/etc/prosody/apns_voip2.crt"
	push_appserver_apns_key = "/etc/prosody/apns_voip2.key"
	ssl = {
		key = "/etc/prosody/certs/push2.example.org.key";
		certificate = "/etc/prosody/certs/push2.example.org.crt";
	}
```

## Usage notes (configuration)

For chat apps using VoIP pushes to APNS, the priority should be set to `high`.
The alert text can be ignored in this case (if you only want to wakeup your
device). For normal push notifications, the priorities `high` and `silent` are
supported. The configured alert text (`push_appserver_apns_push_alert`) is
ignored for `silent` pushes.

For pushes to FCM the priorities `high` and `normal` are supported with `normal`
priorities being delayed while the device is in doze mode.
Pushes having priority `high` are always delivered, even in doze mode, thus
should be used for chat apps.

### Configuration options (mod\_push\_appserver)

- **push\_appserver\_debugging** *(boolean)*  
  Make `/push_appserver/v1/settings` HTTP endpoint available. Default: `false`.  
  This setting will also make http forms available at all `POST` HTTP endpoints
  for easier manual testing of your setup by simply using your browser of choice.
- **push\_appserver\_rate\_limit** *(number)*  
  Allow this much requests per second. Default: 5.  
  This should mitigate some DOS attacks.

### Configuration options (mod\_push\_appserver\_apns)

- **push\_appserver\_apns\_cert** *(string)*  
  Path to your APNS push certificate in PEM format.
- **push\_appserver\_apns\_key** *(string)*  
  Path to your APNS push certificate key in PEM format.
- **push\_appserver\_apns\_capath** *(string)*  
  Path to CA certificates directory. Default: `"/etc/ssl/certs"` (Debian and
  Ubuntu use this path for the system CA store).
- **push\_appserver\_apns\_ciphers** *(string)*  
  Ciphers to use when establishing a tls connection. Default:
  `ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256`
- **push\_appserver\_apns\_sandbox** *(boolean)*
  Use apns sandbox api endpoint if `true`, production endpoint otherwise.
  Default: `true`.
- **push\_appserver\_apns\_mutable\_content** *(boolean)*  
  Mark high prio pushes as mutable content (only useful if `push_appserver_apns_push_priority` is set to
  `"high"` or `"auto"`). Default: `true`.
- **push\_appserver\_apns\_push\_ttl** *(number)*  
  TTL for push notification in seconds. Default: `nil` (that means infinite).
- **push\_appserver\_apns\_push\_priority** *(string)*  
  Value `"high"` for high priority pushes always triggering a visual indication on the user's phone,
  `"silent"` for silent pushes that can be delayed or not delivered at all but don't trigger
  a visual indication and `"auto"` to let the appserver automatically decide between `"high"` and `"silent"`
  based on the presence of `"last-message-body"` in the push summary received from the XMPP server. Default: `"auto"`.  
  **NOTE 1 (iOS >= 13):** Apple decided for iOS >= 13 to not allow silent voip pushes anymore. Use `"high"` or `"auto"` on
  this systems and set `push_appserver_apns_mutable_content` to `true`. Then use a `Notification Service Extension` in your app
  to log in into your XMPP account in the background, retrieve the acutal stanzas and replace the notification with a useful
  one before the dummy notification sent by this appserver hits the screen.  
  **NOTE 2 (iOS >= 10 and < 13):** if you have VoIP capabilities in your app `"silent"` pushes will become reliable and always
  wake up your app without triggering any visual indications on the user's phone.
  In VoIP mode your app can decide all by itself if it wants to show a notification to the user or not
  by simply logging into the XMPP account in the backround and retrieving the stanzas that triggered the push.
- **push\_appserver\_apns\_feedback\_request\_interval** *(number)*  
  Interval in seconds to query Apple's feedback service for extinction of
  invalid tokens. Default: 24 hours.

### Configuration options (mod\_push\_appserver\_fcm)

- **push\_appserver\_fcm\_key** *(string)*  
  Your FCM push credentials (can be found in FCM dashboard under Settings --> Cloud Messaging --> Server key).
- **push\_appserver\_fcm\_capath** *(string)*  
  Path to CA certificates directory. Default: `"/etc/ssl/certs"` (Debian and
  Ubuntu use this path for the system CA store).
- **push\_appserver\_fcm\_ciphers** *(string)*  
  Ciphers to use when establishing a tls connection. Default:
  `ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256`
- **push\_appserver\_fcm\_push\_ttl** *(number)*  
  TTL for push notification in seconds, can be 4 weeks at max.
  Default: `nil` (that means 4 weeks).
- **push\_appserver\_fcm\_push\_priority** *(string)*  
  Value `"high"` for high priority pushes that wake up the device even when
  in doze mode or `"normal"` for normal pushes that can be delayed.
  Default: `"high"`.

## API (register device etc.)

This appserver implements [XEP-0357][1] commands for sending actual push notifications.
Additionally [XEP-0357][1] requires a device to be registered on the appserver but does
not dictate how this should be done.

**Therefore this appserver provides two different APIs to register a (new) device on the appserver.**
**Just use the one more convenient to you.**

### [XEP-0050][6] Ad-Hoc Command API

This API resembles more or less what Conversations is doing,
but with some small differences:
- the command is named "v1-register-push" instead of "register-push-gcm"
- the device id field is called "node" instead of "device-id"
- the new field "type" was added. This can be used to specify the push
  type just as it is done using the http based API.
- You can only register the device using this API, no unregister possible (use the HTTP API for unregistering devices)

[This Gist][5] demonstrates the changes needed to Conversations to use this appserver
instead of inputmice's p2.
See [XEP-0050][6] for more info regarding Ad-Hoc Commands in general.

**Keep in mind that the registration command sent to this appserver is routed through the user's xmpp server.**
**This exposes the raw APNS/FCM push token and device id to the user's xmpp server.**
**Use the HTTP API if you don't like this.**

Example XMPP flow for registering a device:  
```
<iq to="push.example.org" id="MyID-6465" type="set">
	<command xmlns="http://jabber.org/protocol/commands" node="v1-register-push" action="execute">
		<x xmlns="jabber:x:data" type="submit">
		<field var="type">
			<value>fcm</value>
		</field>
		<field var="node">
			<value>static_device_id_like_ANDROID_ID</value>
		</field>
		<field var="token">
			<value>dynamic_token_obtained_from_FirebaseInstanceId_InstanceId</value>
		</field>
		</x>
	</command>
</iq>

<iq to="user@example.com/res1" from="push.example.org" type="result" id="MyID-6465">
	<command xmlns="http://jabber.org/protocol/commands" status="completed" node="v1-register-push" sessionid="1559985918910">
		<x xmlns="jabber:x:data" type="form">
			<field type="jid-single" var="jid">
				<value>push.example.org</value>
			</field>
			<field type="text-single" var="node">
				<value>echoed_back_static_device_id_like_ANDROID_ID</value>
			</field>
			<field type="text-single" var="secret">
				<value>some_arbitrary_hash_like_value</value>
			</field>
		</x>
	</command>
</iq>
```

The two values `node` and `secret` are needed for registering push on the XMPP server afterwards,
see [example 9 in XEP-0357, section 5][7].

### HTTP API

All `POST` endpoints can be used via `GET` to get back a simple html form which
allows you to manually test the endpoint behaviour in your browser, if the config
option `push_appserver_debugging` is set to true (an error is returned otherwise).
*This config option should be false in production environments!*

- POST to `http://<host>:5280/push_appserver/v1/register` or
  `https://<host>:5281/push_appserver/v1/register`  
  POST data: `type=<push type>&node=<device uuid>&token=<apns/fcm/etc. push token>`  
  function: register device for push  
  result: text document separated by `\n`  
  - first line: `OK`, everything else (including `ERROR`) is specified as error
    condition
    if ok: 2nd line: XEP-0357 push `node`, 3rd line: XEP-0357 push `secret`  
    if error: 2nd and subsequent lines: error description

- POST to `http://<host>:5280/push_appserver/v1/unregister` or
  `https://<host>:5281/push_appserver/v1/unregister`  
  POST data: `type=<push type>&node=<device uuid>`  
  function: unregister device  
  result: text document separated by `\n`  
  - first line: `OK`, everything else (including `ERROR`) is specified as error
    condition  
    if ok: 2nd line: XEP-0357 push `node`, 3rd line: XEP-0357 push `secret`  
    if error: 2nd and subsequent lines: error description

- POST to `http://<host>:5280/push_appserver/v1/push` or
  `https://<host>:5281/push_appserver/v1/push`  
  POST data: `node=<device uuid>&secret=<secret obtained on register>`  
  function: send push notification to device  
  result: text document separated by `\n`  
  - first line: `OK`, everything else (including `ERROR`) is specified as error
    condition  
    if ok: 2nd line: XEP-0357 push `node`  
    if error: 2nd and subsequent lines: error description

- GET to `http://<host>:5280/push_appserver/v1/settings` or
  `https://<host>:5281/push_appserver/v1/settings`  
  function: get list of registered device UUIDs  
  result: html site listing all registered device UUIDS as links

- GET to `http://<host>:5280/push_appserver/v1/settings/<device uuid>` or
  `https://<host>:5281/push_appserver/v1/settings/<device uuid>`  
  function: get internal data saved for this device UUID  
  result: HTML site listing all data (serialized Lua table using penlight's
  `pl.pretty`)

- GET to `http://<host>:5280/push_appserver/v1/health` or
  `https://<host>:5281/push_appserver/v1/health`  
  function: get health status of module  
  result: html site containing the word `RUNNING` if the module is loaded properly
  (this GET-node is accessible even when `push_appserver_debugging` is set to `false`)

## Implementation notes

mod\_push\_appserver and its submodules use events to communicate with each
other. These events are documented here.

### Interaction between mod\_push\_appserver and its submodules

mod\_push\_appserver triggers the event `incoming-push-to-<push type>`
(currently only the types `apns` and `fcm` are supported).
The event handler has to return `true` or an error description string
for failed push attempts and `false` for successfull ones.  
Returning `nil` will be handled as error!  
The event data always includes the following keys:

- **origin**  
  Prosody session the stanza came from (typically an s2s session).
- **settings**  
  The registered push settings which are also available at the
  `/push_appserver/v1/settings/<device uuid>` HTTP endpoint in debug mode.
- **summary**  
  The push summary (see [XEP-0357][1] for more information)
- **stanza**  
  The incoming push stanza (see [XEP-0357][1] for more information).

Submodules (like mod\_push\_appserver\_apns) can trigger the event
`unregister-push-token`. The event data has to include the following keys:

- **token**  
  The push token to invalidate (note: this is not the secret obtained by
  registering the device, but the raw token obtained from APNS, FCM etc.).
- **type**  
  `apns`, `fcm` etc.
- **timestamp**  
  The timestamp of the delete request. mod\_push\_appserver won't unregister the
  token if it was re-registered after this timestamp.

### Example of internal data

```lua
{
  type = "apns",
  token = "DEADBEEFABCDEF0123456DEADBEEF112DEADBEEFABCDEF0123456DEADBEEF112",
  last_push_error = "2017-03-18T04:07:44Z",
  last_successful_push = "2017-03-18T03:54:24Z",
  registered = "2017-03-17T02:10:21Z",
  renewed = "2017-03-18T02:54:51Z",
  node = "E0FF1D8C-EB96-4E10-A912-F68B03FD8D3E",
  secret = "384e51b4b2d5e4758e5dc342b22dea9217212f2c4886e2a3dcf16f3eb0eb3807"
}
```

[1]: https://xmpp.org/extensions/xep-0357.html
[2]: https://prosody.im/
[3]: https://developer.apple.com/go/?id=push-notifications
[4]: https://firebase.google.com/docs/cloud-messaging/
[5]: https://gist.github.com/tmolitor-stud-tu/a1e877a7d75c07c2163c3ce1e0347881
[6]: https://xmpp.org/extensions/xep-0050.html
[7]: https://xmpp.org/extensions/xep-0357.html#example-9
