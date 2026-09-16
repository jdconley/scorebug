# Local network impairment implementation plan

> **For agentic workers:** Use bounded independent review. Parent owns implementation
> and all native/media execution in the validation worktree.

**Goal:** Qualify native transport observations under controlled bidirectional
bandwidth/delay/loss while proving local recording remains independent.

**Architecture:** A loopback-only UDP proxy shapes opaque datagrams separately in
both directions. A pure bounded token-bucket queue supplies deterministic scheduling
and accounting. Existing native dual-output scenarios gain an explicit impairment
mode; regular scenarios and their gates remain unchanged.

**Tech stack:** Node UDP sockets and node:test; real Swift sender/libsrt/VideoToolbox;
owned FFmpeg receiver; existing barcode, audio-marker and archive qualification.

## Design

Use application-owned loopback sockets instead of changing machine-wide networking.
The frontend binds port zero and pins the first loopback sender endpoint. The backend
connects only to the explicitly supplied loopback receiver port. Unknown frontend
senders are discarded. No forwarding target may be a non-loopback address.

Each direction has a fixed-capacity FIFO queue, fixed datagram/byte bounds, a byte
rate token bucket with an explicit bounded burst, propagation delay, and optional
periodic deterministic loss. Charge datagram length plus 28 bytes of IPv4/UDP headers;
SRT headers are already inside each UDP datagram. Delay does not consume rate tokens.
At departure, refill using actual elapsed monotonic time and subtract actual wire
bytes; timer delays cannot manufacture extra credits beyond the burst. One timer per
direction and bounded pending sends prevent queued callbacks from hiding memory use.
Close cancels timers, discards queued datagrams explicitly and joins socket closure.

The proxy records received/forwarded/injected-drop/overflow/oversize/close-discard
packet and byte counts, queue peaks and actual forwarding timestamps. It is a local
fixture, not production relay software or a claim of physical radio fidelity.
Configured bitrate is a ceiling plus the documented burst, not promised throughput.

## Task 1: Deterministic queue

Files: `scripts/udp-impairment.mjs`, `scripts/test/udp-impairment.test.mjs`.

- [ ] Write failing tests for FIFO delay, IPv4/UDP byte accounting, token refill,
  capped idle credits, packet/byte/oversize bounds, deterministic loss, clock reversal,
  configuration validation and terminal close. Example:
  ```js
  const queue = new DatagramImpairmentQueue({rateBitsPerSecond: 1024,
    burstBytes: 256, maxDatagramBytes: 128, delayMilliseconds: 100});
  queue.enqueue(Buffer.alloc(100), 0);
  assert.equal(queue.takeReady(99), null);
  assert.equal(queue.takeReady(100).length, 100);
  ```
- [ ] Implement queue/snapshot conservation and verify deterministic rate-envelope
  tests over multiple windows with burst allowance; no real timers in pure tests.

## Task 2: Owned sockets

Files: same module and tests.

- [ ] Add `createUDPImpairmentProxy({receiverPort, forward, reverse})`, returning
  `{port, snapshot(), close()}`. Bind only 127.0.0.1; use one timer and at most 16
  pending datagrams per direction. Ignore foreign frontend endpoints.
- [ ] Real UDP tests verify bidirectional payload preservation, distinct directional
  loss/delay, foreign-peer rejection, bounded queue accounting and idempotent joined
  cleanup. Force cleanup with test hooks even when an assertion fails.

## Task 3: Native qualification

Files: `scripts/test-dual-output.mjs`, `package.json`, documentation.

- [ ] Add explicit `--impairment` mode and `test:native-network` command. Reuse
  source/build/archive helpers. Scenarios: transparent bounded proxy, recoverable
  rate/delay/loss on both directions, and sender overload below initial bitrate.
- [ ] Keep all archive gates and normal live frame/A/V/clock/bitrate/statistics gates
  for transparent/recoverable cases. Require actual bidirectional proxy traffic and
  injected effects; record exact proxy configuration and terminal queue conservation.
- [ ] For deliberate overload require bounded shaping with actual queue pressure or
  drops and complete archive; inspect and report acquired live decode/frame/cadence
  results separately. Do not label degraded live output qualified or relax normal
  acceptance gates. Automatic quality is still disabled.
- [ ] Run full tooling suite and real native network scenarios. Review, document
  results with source/evidence hashes, and commit verified work. Use failures to
  determine the next capacity/control implementation; do not turn estimates into
  usable video capacity merely because a short local test passes.

Commands: `node --test scripts/test/udp-impairment.test.mjs`, `pnpm test:tools`, and
`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:native-network`.
