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
Close cancels timers, discards queued datagrams explicitly and joins pending send callbacks before socket closure.

The proxy records received/forwarded/injected-drop/overflow/oversize/close-discard
packet and byte counts, queue peaks and actual forwarding timestamps. It is a local
fixture, not production relay software or a claim of physical radio fidelity.
Finite configured rates must be at least 1 bit/s to keep bounded datagram waits within
Node’s timer range. Configured bitrate is a ceiling plus the documented burst, not promised throughput.

## Task 1: Deterministic queue

Files: `scripts/udp-impairment.mjs`, `scripts/test/udp-impairment.test.mjs`.

- [x] Write failing tests for FIFO delay, IPv4/UDP byte accounting, token refill,
      capped idle credits, packet/byte/oversize bounds, deterministic loss, clock reversal,
      configuration validation and terminal close. Example:
    ```js
    const queue = new DatagramImpairmentQueue({
        rateBitsPerSecond: 1024,
        burstBytes: 256,
        maxDatagramBytes: 128,
        delayMilliseconds: 100,
    });
    queue.enqueue(Buffer.alloc(100), 0);
    assert.equal(queue.takeReady(99), null);
    assert.equal(queue.takeReady(100).length, 100);
    ```
- [x] Implement queue/snapshot conservation and verify deterministic rate-envelope
      tests over multiple windows with burst allowance; no real timers in pure tests.

## Task 2: Owned sockets

Files: same module and tests.

- [x] Add `createUDPImpairmentProxy({receiverPort, forward, reverse})`, returning
      `{port, snapshot(), close()}`. Bind only 127.0.0.1; use one timer and at most 16
      pending datagrams per direction. Ignore foreign frontend endpoints.
- [x] Real UDP tests verify bidirectional payload preservation, distinct directional
      loss/delay, foreign-peer rejection, bounded queue accounting and idempotent joined
      cleanup. Force cleanup with test hooks even when an assertion fails.

## Task 3: Native qualification

Files: `scripts/test-dual-output.mjs`, `package.json`, documentation.

- [x] Add explicit `--impairment` mode and `test:native-network` command. Reuse
      source/build/archive helpers. Scenarios: transparent bounded proxy, recoverable
      rate/delay/loss on both directions, and sender overload below initial bitrate.
- [x] Keep all archive gates and normal live frame/A/V/clock/bitrate/statistics gates
      for transparent/recoverable cases. Require actual bidirectional proxy traffic and
      injected effects; record exact proxy configuration and terminal queue conservation.
- [x] For deliberate overload require bounded shaping with actual queue pressure or
      drops and complete archive; inspect and report acquired live decode/frame/cadence
      results separately. Do not label degraded live output qualified or relax normal
      acceptance gates. Automatic quality is still disabled.
- [x] Run full tooling suite and real native network scenarios. Review, document
      results with source/evidence hashes, and commit verified work. Use failures to
      determine the next capacity/control implementation; do not turn estimates into
      usable video capacity merely because a short local test passes.

Commands: `node --test scripts/test/udp-impairment.test.mjs`, `pnpm test:tools`, and
`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:native-network`.

## Verification checkpoint

The real-socket regression reproduced close returning with one pending reverse send.
Waiting for socket close and send callbacks concurrently can hang because closing an
unconnected UDP socket can discard an unresolved send callback. Final shutdown joins
bounded pending callbacks first, then closes both sockets. Both directions now have
actual pending-send regression coverage.

The first overload run exposed misleading diagnostic output: corrupted frame codes
caused all decoded frames to be reported as zero. The new pure diagnostic helper
preserves complete raw sample counts independently of valid source identities and
withholds identity-based frame rate/loss when markers are unusable. Strict normal
media gates remain unchanged. Focused tests pass 33/33; the full tooling suite passes
694/694. Independent review approves the final source.

Final network evidence is `artifacts/qa/dual-output-9tQV92`. Every archive retains all
420 frames. Transparent and recoverable live paths also retain all 420 frames with
full media/clock/statistics/bitrate gates. Recoverable shaping injects 62 forward and
eight reverse packet losses without queue overflow. Overload drops 4,097 forward
packets at its bounded 32 KiB queue, and strict live decode correctly fails. Its
best-effort decoder emits 389 frames with invalid source identities; identity-based
cadence/loss remain null. All owned proxy queues and pending callbacks join empty,
with no socket errors. Peak native RSS stays below 96 MiB.

Red logs preserve queue, socket, timer-range, pending-close and damaged-marker cases.
The original five-scenario suite passes at `artifacts/qa/dual-output-2SuTzI`:
all five archives retain 420 frames, both normal streams retain 420 frames, and
maximum producer lag stays below 9 ms. The prior run `dual-output-IrG5NS` remains
failed: its normal producer reached 261.613 ms against the unchanged 250 ms limit.
That run reported all 420 frames submitted with no archive/live rejection, but stopped
before normal archive/live decode qualification. The unchanged repeat passes; the
intermittent scheduling cause has not been established and is not declared fixed.
Final source/evidence hashes are recorded in
`artifacts/qa/local-network-impairment-final-verification.json`.

Next qualify time-aligned transport pressure and explicit overhead accounting using
these impaired traces. Do not infer spare video capacity from sent throughput or
SRT's bandwidth estimate, and do not enable automatic increases without the remaining
policy-window and profile-transition evidence.
