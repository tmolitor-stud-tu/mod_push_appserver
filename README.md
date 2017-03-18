# mod_push_appserver
Simple and extendable appserver for XMPP pushes (aka. XEP-0357)

A better readme is coming soon.

## Notes
The appserver is implemented as a module for the prosody XMPP server (usable on prosody 0.9 or later) and written in lua (version 5.1).

Currently only push to apples APNS is implemented, but other push services like GCM can easily be added in a separate module.

`mod_push_appserver_apns` needs APNS client certificate and key files in the module directory under the name `push.pem` (cert in pem fomat) and `push.key` (key in pem format, no password!)

Currently the APNS module should only used for VOIP pushes as the pushes have a hardcoded dummy payload and are `HIGH` priority pushes.
The TTL of those pushes is set to 24 hours.

If you want to change this to your needs, just patch the line calling `create_frame()` accordingly.

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
