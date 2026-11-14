# Native runtime

The runtime pins Tailscale **1.104.7** and Go **1.27.4**. Build with
`scripts/build-native.sh <OS> <architecture> <absolute-output>` from the project
root. Android needs the NDK; its ABI names are accepted. The native compiler API
floor is 35 (override with `ANDROID_API`), while the host app minimum remains 36.
Native binaries are build outputs and must not be committed.

Desktop control uses bounded NDJSON on inherited stdin/stdout. Android exposes
`ft_request` / `ft_free` with the same JSON contract. Control requests carry an
`id`, `method`, and `params`; responses contain `id` and `result` or a sanitized
`error`. The maximum frame is 1 MiB. This is implementation protocol version 1,
not the earlier design's proposed length-prefixed JSON-RPC format.

Initialization does not start a node. `login` opts into persistent restoration;
`start` requires the durable resume marker. State lives exclusively in the
host-selected private application directory. A cross-process lock rejects
another owner. Each initialize attaches an `ownerId`; dispose closes only that
owner's resources, stopping the node after the final owner leaves. Explicit
stop/logout are application-wide. Logout clears only the SDK's node subdirectory
and disables restoration before network notification, preserving host data.

Forward leases bind stable node identity, local registration scope, port and
session. They expire after 60 seconds for new connections. Local TLS verifies
the helper before CONNECT capabilities are sent; inbound targets require pinned
mutual TLS. Service source lists are explicit, default-deny peer references.
Revocation closes existing streams as well as listeners. No media protocol is
parsed and no failed stream is silently replayed. gRPC is supported; arbitrary
protocols requiring unbounded TCP half-close are not claimed.

Android must supply `networkChanged` snapshots before starting. The snapshot is
registered through upstream netmon's interface getter, avoiding Android's
restricted netlink interface enumeration. Runtime lifecycle and network callbacks
remain the host's responsibility. No VPN service or system Tailscale install is
required. This mechanism still requires device and background-engine validation.

Tests use a fake backend for transport/authorization, exercising real local TLS
and sockets without a Tailscale account. A passing test is not proof of internet,
DERP, carrier NAT, or mobile background connectivity.

The implementation polls bounded status snapshots rather than exposing the
design document's proposed ordered event protocol. Control cancellation does
not interrupt a request already dispatched into the native runtime; status,
login notification, and data-plane dials have bounded deadlines. Revocation and
owner disposal close associated sockets. A local registration scope is hashed
from the validated self stable-node ID and user ID; it is not a global tailnet
identifier and changes on local node re-registration/account changes.

Upstream logtail is disabled before starting tsnet. Discarding `UserLogf` alone
is insufficient because tsnet forwards its login URL to logtail first. The
pinned implementation drops entries before its disk buffer and opts out of
log-upload transport; authentication URLs only traverse the initiating owner's
control responses. Ambient `TS_AUTHKEY` / OAuth credentials are rejected.

On macOS the embedded node follows the operating system's routes instead of
using upstream's default physical-interface binding for its system VPN daemon.
The embedded userspace node creates no system TUN/routes; forcing a physical
interface can bypass another VPN's working route and stall authentication.
This setting is process-local and does not modify system VPN/proxy settings.

`python3 scripts/smoke-native.py <helper>` checks the real helper with disposable
state. Add `--anonymous-login` to request and observe an official sign-in URL,
check that it was not logged, then log out and remove that temporary state. The
script never prints or opens the URL and does not authenticate any account.
