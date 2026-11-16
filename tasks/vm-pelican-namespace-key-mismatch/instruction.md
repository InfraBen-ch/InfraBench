You are the on-call engineer for a private Pelican federation used by the
Syscraft data pipeline.

The deployment is spread across three VMs:

- `node0`: Pelican Registry and Director.
- `node1`: Pelican Origin for namespace `/syscraft/public`.
- `node2`: Pelican Cache and the client validation node.

After an Origin host rebuild, the services appear partly healthy but reads for
`/syscraft/public/payload.txt` through the federation fail or route to an
untrusted provider. The last known good object content and checksum are recorded
under `/etc/syscraft/pelican-incident.env` and `/opt/syscraft-pelican/expected/`
on the nodes.

Restore object access through Pelican. The correct repair should reconcile the
Registry namespace approval with the active Origin identity/key material, then
restart or refresh the relevant Pelican services so Director routes
`/syscraft/public/...` to the live Origin and Cache path.

Do not rebuild the whole federation from scratch, do not change the expected
dataset or checksum, and do not serve the file with plain HTTP or another
ad-hoc bypass outside Pelican.
