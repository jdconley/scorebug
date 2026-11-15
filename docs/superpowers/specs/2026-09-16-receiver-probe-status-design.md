# Authenticated receiver probe status

Extend the existing private relay lookup and native status contract with receiver
probe snapshots. This is the delivery/freshness boundary needed by the later
capacity policy; it does not authorize an upgrade or start optional traffic.

The API follows the current worker reader to its authenticated publisher and
verifies the signed application publishing attempt. It returns mutable probe
measurements beside, never inside, `WorkerPublication`. The entire reporting scope
is checked again after private I/O. A changed broadcast, worker session, attempt,
or read identity discards both association and measurements.

`receiverProbe` contains a sanitized `snapshot` and server-owned
`ageUpperBoundMs`. Snapshot fields follow `mpegts-null-probe-v1`: canonical UUID,
UInt64 generation string, 1…2,000,000 accounted bit rate, complete-message/byte
counters, pending packet count, receiver-relative read/observation nanoseconds,
and optional receiver invalidity. Snapshots are bounded to 16 MiB and a 24-hour
receiver clock, matching the qualified fixture envelope. Unknown fields are
stripped. The byte budget reserves a complete next message before accepting any
partial packet. Explicit null optional snapshot fields are invalid. Invalid optional measurements do not discard ordinary publication.

The age upper bound is the rounded-up monotonic duration from before the private
relay call through the final status sample. This conservatively includes the
snapshot-to-API interval. The native helper adds the entire client request and
local residence, uses the existing status lease, and separately reports the age
of last completed delivery. A new poll of unchanged counters must not refresh the
last delivery. The future interval/capacity policy must apply its own delivery-age
threshold; a fresh status alone does not make an old count useful. Native acceptance requires an explicit locally owned expectation:
match, broadcast generation, worker, application publishing attempt, native
publishing generation, probe UUID, and requested bit rate. It captures immutable
worker session/attempt and publication identity. Missing, malformed, contradictory,
expired, or differently scoped data produces no usable evidence.

Native status reads bypass the local URL cache and send `no-cache, no-store`;
private relay requests also send that header. Public match/status responses already
carry `no-store`, now covered by a regression.

Implement this contract in the production API and shared iPhone/Watch core now.
Wiring a production probe owner, repeated/staged probing, causal multi-observation
intervals, candidate cost, and automatic upgrades remain the following phase.
The existing actual media trial remains evidence for marked probe delivery; it is
not evidence that these future adaptation steps work.
