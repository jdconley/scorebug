# Scoped phone relay forwarder

Implement after the typed client and atomic binding checkpoint with TDD and
independent review. The phone relay is app scoped and independent of the selected
Film, Score or Watch tab. It must not read camera state or phone scorer credentials.

Accept only codec-valid bounded scoring requests and compare the entire scope to
the currently published durable pairing binding before constructing an HTTP client
from that binding's canonical endpoint. Pass the request's Watch credential and
exact command to snapshot/execute/receipt. Do not expose arbitrary HTTP paths,
installation operations or phone credentials. Server authentication still decides
whether the opaque Watch token is valid.

Own at most one HTTP task. A second admitted request receives correlated busy.
Binding/peer changes invalidate the request generation before canceling work;
retain busy ownership until the old task terminates. A late HTTP success cannot
become a successful reply for an invalidated generation. Do not resend mutations,
cache success responses, or manufacture receipt absence from transport errors.
Only the existing client's authoritative receipt-not-found behavior yields nil.

Use a configurable finite HTTP attempt deadline and recheck its monotonic deadline
before accepting a reply. Initial local integration budget: three seconds on the
phone inside the Watch's four-second message attempt. Timeout cancels the owned
HTTP task, but the owner remains busy until that cancellation joins. These initial
values still need combined route-budget and physical latency qualification; they
must not silently inherit the current generic client's twenty-second timeout.

Map typed authentication and HTTP failures to sanitized relay errors. A malformed
or unbounded server model becomes invalidResponse after strict reply encoding.
No raw error strings, bearer tokens or response bodies enter the relay error path.
Malformed incoming bytes cannot supply a trusted correlation identity; return an
empty bounded response so the caller fails decoding rather than waiting indefinitely.

Tests use an injected client and controlled response suspension: every allowed
operation, exact endpoint/credential/command forwarding, full scope mismatch and
malformed inputs before dispatch, authoritative absence versus failure, busy limits,
peer/binding change during HTTP, cancellation join, timeout and late callback, plus
server commit/lost companion reply recovery through the real durable coordinator.
The native delegate must acquire bounded admission before creating actor tasks;
model-only tests do not prove this platform integration or background execution.
