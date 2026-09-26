# Event-driven upload impairment implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development, with specification then quality review before commit.

**Goal:** Apply and remove one real upload bandwidth constraint when the ordinary native test observes the corresponding quality transitions.

**Architecture:** Extend the owned UDP test proxy with an explicit one-constraint mode and an optional local IPv4 receiver address. Keep its loopback frontend, existing scheduled mode, bounded queues, token accounting and joined socket cleanup. A later ordinary-runner integration will own the private control endpoint and verify native event timing.

**Tech stack:** Node UDP sockets, monotonic clock, existing DatagramImpairmentQueue and RateLedgerObserver.

## Contract

- `receiverHost` defaults to `127.0.0.1`. Accept numeric loopback or RFC1918 IPv4 only; reject wildcard, multicast, broadcast, public IPs, IPv6, DNS and URL syntax before socket allocation. The frontend stays bound to127.0.0.1 and permits one loopback publisher. This helper change enables the simulator route to the local LAN relay, not physical-phone ingress.
- Optional `forwardRateControl: { rateBitsPerSecond: number }` declares one finite rate in the existing allowed finite range. Reject unknown keys, null/array/malformed controls, initial finite forward rate and any simultaneous `forwardRateSchedule`. Copy configuration so caller mutation cannot change the rate.
- Only selected control mode exposes `constrainForward()` and `restoreForward()`. A first accepted publisher packet starts baseline evidence. Constrain requires a peer and baseline state; restore requires the constrained state. Duplicate, reversed, pre-peer or post-close calls fail before queue mutation.
- Each transition uses one actual monotonic timestamp and the existing queue `setRate`. Capture the after-change/pre-pump boundary required by the rate ledger, then pump so restoration drains the existing FIFO promptly. Never clear the queue, reset tokens, alter deadlines or affect reverse configuration.
- Retain at most three phase records: baseline, constrained and restored, with requested rate, actual applied time and bounded direction snapshots after the change and before pumping. Retain the existing bounded timeline in these snapshots because `qualifyRateLedger` checks exact boundary bins; do not substitute scalar totals for required evidence. Snapshot only at these three transitions, never per packet or poll, and do not copy the ledger into phase records. Return detached transition receipts; snapshots/caller mutations cannot mutate owned evidence.
- Snapshot includes requested mode/rate, actual start/stop times and completed phases. Close during baseline/constrained state retains an incomplete sequence; never invent restoration or a passing verdict. Close remains idempotent and joins sends/sockets/timers. Default/scheduled snapshots and timing contracts remain unchanged.

## Files and steps

Files: `scripts/udp-impairment.mjs`, `scripts/test/udp-impairment-sockets.test.mjs`, and a separate `scripts/test/udp-impairment-control.test.mjs` if this keeps the socket suite focused. No app, policy, worker, legacy qualifier or lab integration changes in this slice.

- [ ] Add and run behavioral failing tests for explicit receiver routing and event-controlled constraint/restoration.
- [ ] Implement validated receiver selection and the bounded control state machine above.
- [ ] Verify real UDP forward/reverse payloads, foreign-peer rejection, pre-peer/out-of-order/duplicate/post-close rejection without mutation, caller/receipt mutation isolation, pending FIFO restoration and interrupted close. Test socket destination with a locally bound receiver and inspect the actual connect address; never send test data to an arbitrary LAN host.
- [ ] Verify a real constrained phase produces token denial, bounded queue/pending counts, exact conservation and rate-ledger qualification using the new boundary receipts. Default and scheduled socket/ledger tests must stay green.
- [ ] Run `node --test scripts/test/udp-impairment*.test.mjs scripts/test/rate-ledger*.test.mjs scripts/test/uplink-schedule-qualification.test.mjs scripts/test/measured-capacity-uplink.test.mjs` and syntax/format checks for touched files. Preserve red/green logs and exact final blobs.
- [ ] Independent specification review followed by quality review, resolve findings, then commit. A proxy unit/socket pass is not an ordinary native recovery pass.

Representative integration shape:

```js
const proxy = await createUDPImpairmentProxy({
  receiverHost: '127.0.0.1', receiverPort: receiver.address().port,
  forward: { recordTimeline: true, recordRateLedger: true },
  forwardRateControl: { rateBitsPerSecond: 750000 },
});
// Send and observe the actual first publisher datagram before this call.
const limited = proxy.constrainForward();
// After the native test observes minimum acknowledgment:
const restored = proxy.restoreForward();
await proxy.close();
// Feed exact after-change/pre-pump boundary snapshots and the complete ledger
// to qualifyRateLedger. The later runner separately establishes native causality.
```

Keep request/response HTTP handling outside this helper. The proxy cannot itself
prove native acknowledgment or trial confirmation; the ordinary test and its
independent qualifier must bind those facts to these actual phase boundaries.
