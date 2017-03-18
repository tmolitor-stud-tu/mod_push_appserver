# mod_push_appserver
Simple and extendable appserver for XMPP pushes (aka. XEP-0357)

A better readme is coming soon.

## TODO
Periodically (about once a day) query apple's feedback service to react to failed pushes (remove push settings for given device).

## Requirements

- Prosody 0.9 or later
- Lua 5.1 (5.2 should also work, but is untested)
- Installed penlight lua library (debian package: `lua-penlight`)
- Installed luasec lua library version 0.5 (debian package: `lua-sec`), higher versions are untested

## Notes
The appserver is implemented as a module for the prosody XMPP server (usable on prosody 0.9 or later) and written in lua (version 5.1).

Currently only push to apples APNS is implemented, but other push services like GCM can easily be added in a separate module.

`mod_push_appserver_apns` needs APNS client certificate and key files in the module directory under the name `push.pem` (cert in pem fomat) and `push.key` (key in pem format, no password!)

For VOIP pushes the priority should be set to "high", the alert text can be ignored in this case if you only want to wakeup your device.
For normal pushes priorities "high" and "silent" are supported. The configured alert text (`push_appserver_apns_push_alert`) is ignored for silent pushes.

### Interaction between mod_push_appserver and mod_push_appserver_apns
mod_push_appserver triggers the event `incoming-push-to-<push type>` (currently only the type `apns` is supported)
The event data includes the following keys:
- origin: prosody session the stanza came from (typically an s2s session)
- settings: the registered push settings available at `/push_appserver/v1/settings/<device uuid>` http endpoint
- stanza: the incoming push stanza (see XEP-0357 for more info)

### http API endpoints
- POST to `http://<host>:5280/push_appserver/v1/register` or `https://<host>:5281/push_appserver/v1/register`
  POST data: `type=<push type>&node=<device uuid>&token=<apns push token>`
  function: register device for push
  result: text document separated by `\n`
  - first line: `OK`, everything else (including `ERROR`) is specified as error condition
    if ok: 2nd line: XEP-0357 push `node`, 3rd line: XEP-0357 push `secret`
    if error: 2nd and subsequent lines: error description

- POST to `http://<host>:5280/push_appserver/v1/unregister` or `https://<host>:5281/push_appserver/v1/unregister`
  POST data: `type=<push type>&node=<device uuid>`
  function: unregister device
  result: text document separated by `\n`
  - first line: `OK`, everything else (including `ERROR`) is specified as error condition
    if ok: 2nd line: XEP-0357 push `node`, 3rd line: XEP-0357 push `secret`
    if error: 2nd and subsequent lines: error description

- GET to `http://<host>:5280/push_appserver/v1/settings` or `https://<host>:5281/push_appserver/v1/settings`
  function: get list of registered device UUIDs
  result: html site listing all registered device UUIDS as links

- GET to `http://<host>:5280/push_appserver/v1/settings/<device uuid>` or `https://<host>:5281/push_appserver/v1/settings/<device uuid>`
  function: get internal data saved for this device UUID
  result: html site listing all data (serialized lua table using penlight's pl.pretty)

### Configuration options (mod_push_appserver)
`push_appserver_debugging`: boolean, make `/push_appserver/v1/settings` http endpoint available, default: `false`

### Configuration options (mod_push_appserver_apns)
`push_appserver_apns_capath`: string, path to CA certificates directory, default: `/etc/ssl/certs` (debian and ubuntu use this path for system CA store)
`push_appserver_apns_sandbox`: boolean, use apns sandbox api endpoint if `true`, production endpoint otherwise, default: `true`
`push_appserver_apns_push_alert`: string, alert text for push message, default: "dummy"
`push_appserver_apns_push_ttl`: number, ttl for push notification in seconds, default: 24 hours
`push_appserver_apns_push_priority`: string, value "high" for high priority pushes or "silent" for silent pushes, default: "high"

### Example of internal data
``
{
  type = "apns",
  token = "DEADBEEFABCDEF0123456DEADBEEF112",
  last_push_error = "2017-03-18T04:07:44Z",
  last_successful_push = "2017-03-18T03:54:24Z",
  renewed = "2017-03-18T02:54:51Z",
  node = "E0FF1D8C-EB96-4E10-A912-F68B03FD8D3E",
  secret = "384e51b4b2d5e4758e5dc342b22dea9217212f2c4886e2a3dcf16f3eb0eb3807"
}
``
