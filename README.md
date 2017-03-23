# mod\_push\_appserver

Simple and extendable app server for XMPP push notifications as defined in
[XEP-0357][1].

## Requirements

- Prosody 0.9 or later.
- Lua 5.1 (5.2 should also work, but is untested).
- Installed penlight Lua library (Debian package: `lua-penlight`).
- Installed luasec Lua library version 0.5 (Debian package: `lua-sec`), higher
  versions are untested.

## Notes

The app server is implemented as a module for the [Prosody][2] XMPP server.

Currently, only push notifications to Apple's [APNS][3] are implemented, but
other push services (such as Google's [FCM][4]) can easily be added in a
separate module.

mod\_push\_appserver\_apns needs APNS client certificate and key files in the
module directory under the name `push.pem` (certificate in PEM fomat) and
`push.key` (key in PEM format, no password!).

For VoIP pushes, the priority should be set to `high`. The alert text can be
ignored in this case (if you only want to wakeup your device). For normal push
notifications, the priorities `high` and `silent` are supported. The configured
alert text (`push_appserver_apns_push_alert`) is ignored for `silent` pushes.

### HTTP API endpoints

- POST to `http://<host>:5280/push_appserver/v1/register` or
  `https://<host>:5281/push_appserver/v1/register`  
  POST data: `type=<push type>&node=<device uuid>&token=<apns push token>`  
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

### Configuration options (mod\_push\_appserver\_apns)

- **push\_appserver\_apns\_capath** *(string)*  
  Path to CA certificates directory. Default: `"/etc/ssl/certs"` (Debian and
  Ubuntu use this path for the system CA store).
- **push\_appserver\_apns\_sandbox** *(boolean)*
  Use apns sandbox api endpoint if `true`, production endpoint otherwise.
  Default: `true`.
- **push\_appserver\_apns\_push\_alert** *(string)*  
  Alert text for push message. Default: `"dummy"`.
- **push\_appserver\_apns\_push\_ttl** *(number)*  
  TTL for push notification in seconds. Default: `nil` (that means infinite).
- **push\_appserver\_apns\_push\_priority** *(string)*  
  Value `"high"` for high priority pushes or `"silent"` for silent pushes.
  Default: `"high"`.
- **push\_appserver\_apns\_feedback\_request\_interval** *(number)*  
  Interval in seconds to query Apple's feedback service for extinction of
  invalid tokens. Default: 24 hours.

### Interaction between mod\_push\_appserver and mod\_push\_appserver\_apns

mod\_push\_appserver triggers the event `incoming-push-to-<push type>`
(currently only the type `apns` is supported). The event data includes the
following keys:

- **origin**  
  Prosody session the stanza came from (typically an s2s session).
- **settings**  
  The registered push settings available at
  `/push_appserver/v1/settings/<device uuid>` HTTP endpoint.
- **stanza**  
  The incoming push stanza (see [XEP-0357][1] for more information).

mod\_push\_appserver\_apns triggers the event `unregister-push-token`. The event
data includes the following keys:

- **token**  
  The push token to invalidate (note: this is not the secret obtained by
  registering the device, but the raw token obtained from APNS, FCM etc.).
- **type**  
  `apns`, etc.
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

## TODO

Periodically (about once a day), query Apple's feedback service to react to
failed push notifications (remove push settings for given device).

[1]: https://xmpp.org/extensions/xep-0357.html
[2]: https://prosody.im/
[3]: https://developer.apple.com/go/?id=push-notifications
[4]: https://firebase.google.com/docs/cloud-messaging/
