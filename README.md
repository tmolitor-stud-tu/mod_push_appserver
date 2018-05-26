# mod\_push\_appserver

Simple and extendable app server for XMPP push notifications as defined in
[XEP-0357][1].

The app server is implemented as a module for the [Prosody][2] XMPP server.

Currently, only push notifications to Apple's [APNS][3] and Google's [FCM][4]
are implemented, but other push services can easily be added in a separate
module.

## Requirements

- Prosody 0.9 or later.
- Lua 5.1 (5.2 should also work, but is untested).
- Installed penlight Lua library (Debian package: `lua-penlight`).
- Installed luasec Lua library version 0.5 (Debian package: `lua-sec`), higher
  versions are untested.
 
## Installation

Just check out the repository somewhere and point prosody at this directory
using `plugin_paths` in its main config file.  
For example: `plugin_paths = { "/usr/local/lib/mod_push_appserver" }`.

Then add `mod_push_appserver` and the submodule you need (for example
`mod_push_appserver_apns` or `mod_push_appserver_fcm`) to global
`modules_enabled` or to the enabled modules of a specific virtual host.

I will eventually add a commented minimal configuration example for prosody
to this repository, too.

## Usage notes

For chat apps using VoIP pushes to APNS, the priority should be set to `high`.
The alert text can be ignored in this case (if you only want to wakeup your
device). For normal push notifications, the priorities `high` and `silent` are
supported. The configured alert text (`push_appserver_apns_push_alert`) is
ignored for `silent` pushes.

For pushes to FCM the priorities `high` and `normal` are supported with `normal`
priorities being delayed while the device is in doze mode.
Pushes having priority `high` are always delivered, even in doze mode, thus
should be used for chat apps.

### HTTP API endpoints

All `POST` endpoints can be used via `GET` to get back a simple html form which
allows you to manually test the endpoint behaviour in your browser, if the config
option `push_appserver_debugging` is set to true (an error is returned otherwise).

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

### Configuration options (mod\_push\_appserver)

- **push\_appserver\_debugging** *(boolean)*  
  Make `/push_appserver/v1/settings` HTTP endpoint available. Default: `false`.  
  This setting will also make http forms available at all `POST` HTTP endpoints
  for easier manual testing of your setup by simply using your browser of choice.
- **push\_appserver\_rate\_limit** *(number)*  
  Allow one request per this much seconds. Default: 5 (e.g. one request every 5 seconds).  
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
- **push\_appserver\_apns\_push\_alert** *(string)*  
  Alert text for push message. Default: `"dummy"`.
- **push\_appserver\_apns\_push\_ttl** *(number)*  
  TTL for push notification in seconds. Default: `nil` (that means infinite).
- **push\_appserver\_apns\_push\_priority** *(string)*  
  Value `"high"` for high priority pushes always triggering a visual indication on the user's phone,
  `"silent"` for silent pushes that can be delayed or not delivered at all but don't trigger
  a visual indication and `"auto"` to let the appserver automatically decide between `"high"` and `"silent"`
  based on the presence of `"last-message-body"` in the push summary received from the XMPP server.
  **NOTE**: if you have VoIP capabilities in your app `"silent"` pushes will become reliable and always
  wake up your app without triggering any visual indications on the user's phone.
  In VoIP mode your app can decide all by itself if it wants to show a notification to the user or not
  by simply logging into the XMPP account in the backround and retrieving the stanzas that triggered the push.
  Default: `"silent"`.
- **push\_appserver\_apns\_feedback\_request\_interval** *(number)*  
  Interval in seconds to query Apple's feedback service for extinction of
  invalid tokens. Default: 24 hours.

### Configuration options (mod\_push\_appserver\_fcm)

- **push\_appserver\_fcm\_key** *(string)*  
  Your FCM push credentials.
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
