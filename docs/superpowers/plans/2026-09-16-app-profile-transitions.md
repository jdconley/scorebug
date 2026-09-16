# Native app profile transitions

Continue the stream-lifecycle gate from `a01651b` under the existing autonomous
implementation authorization. Use inline TDD and the existing read-only reviewer.

## Design

Carry a typed live profile and a validated historical format receipt through the
streaming adapter and PublishingSession. Profiles belong to ScorebugMedia (plain
values); the HaishinKit settings mapping remains in ScorebugStreaming. Preserve the
existing ScorebugStreaming type spelling for source compatibility. The receipt
contains requested profile, actual dimensions, old/new encoder IDs and source PTS,
publication generation, raw queue eviction count, and adapter acknowledgment time.
It does not attest achieved bitrate, worker output or current readiness forever.

Use one mutation admission slot for bitrate and profile changes. Both remain
independent of capture and the archive, reject overlapping mutation, and participate
in terminal shutdown. Deadlines and cancellation retire the live attempt after
possible native mutation; shutdown must join the underlying native replacement
before persistence or observation closure. A profile receipt clears the previous
bitrate receipt, which belongs to the replaced encoder.

After typed lifecycle tests pass, add an explicit DEBUG simulator transition fixture
that requests 1080p→540p→1080p at fixed elapsed/source boundaries. It must retain
bounded per-phase actual compressed-format/session/source evidence and the two
receipts after joined stop. Do not reuse the fixed-profile accumulator, which
correctly rejects mixed formats. Production automatic selection stays disabled.

Qualify that fixture through the local worker and direct recorder while the local
archive stays 1080p. Match actual native intervals, source identities, receipt
boundaries, frame loss and output gaps; require complete decode, >=24-fps sustained
coverage, A/V sync and a normally finalized independent archive. Worker output
scaling must not stand in for proof of phone encoder format. Retain failed media
and diagnostics rather than weaken the gates. Then test constrained uplink recovery.

## Work

- [x] Add typed profile/receipt values and constructor tests, preserving profile
  settings and default1080 behavior.
- [x] Add adapter profile mutation with cancellation/stop ownership and mutual
  exclusion with bitrate; test rejected state, late native results and error privacy.
- [x] Add PublishingSession profile admission, two-second deadline, receipt/scope
  validation and joined shutdown; preserve existing bitrate tests.
- [ ] Add the controlled app fixture and runner/verifier options with strict flag
  prerequisites, real phase receipts and bounded scalar evidence.
- [ ] Run Mac packages and app-model tests, unsigned iPhone/Watch build, then the
  owned simulator full-pipeline experiment sequentially. Inspect actual decoded
  output and archive evidence before claiming the transition qualified.
- [ ] Review, record terminal evidence hashes and commit. Continue into pressure,
  recovery and remaining physical/device/other-host gates.

## Typed API checkpoint

`PublishingVideoProfile` now belongs to ScorebugMedia, with a source-compatible
ScorebugStreaming type alias and the native settings mapping left in Streaming.
The new receipt validates dimensions, ordered numeric source PTS, different encoder
IDs, publication generation and acknowledgment clock. It carries actual pre-mux
format evidence only, never an achieved bitrate or receiver-delivery claim.

PublishingSession owns one shared admission/task/deadline for bitrate and profile
mutations. The two-second admission cap is preserved; overlap is rejected before
native dispatch. A profile receipt clears the old bitrate receipt. Cross-kind
checks reject source rewind, missing post-profile bitrate source, and reuse of
known retired or previously observed encoder IDs. They do not assume that every
native encoder recreation is observable in the receipt history. Cancellation,
deadline, bad receipts and native failures retire the attempt, join the owned
operation, and preserve only committed historical evidence.

Both streaming adapter layers join native profile work during shielded stop.
Review exposed an existing-startup interaction with the newly cached native stop:
a late unowned connect could reopen after stop. SRTPublisher now owns startup,
rejects stopped/cancelled/duplicate admission before native dispatch, joins it and
closes again after late completion. Configure also rejects a stopped attempt.

Retained red tests demonstrate the initial missing APIs, cross-kind source rewind,
stopped native startup/configure admission, and retained encoder-ID reuse before
the fixes. Source review approved the corrected startup/stop ownership and receipt
checks. The app continues to select fixed profiles until the separate controlled
transition fixture and decoded downstream qualification are implemented.

Validation for this API checkpoint: 186 media XCTest tests plus 66 Swift Testing
tests, 61 streaming tests, 183 app-model tests, and unsigned combined iPhone/Watch
Release build pass with Xcode 26.2. Test/build processes ran sequentially and were
joined before hashing evidence. No SDK sources changed in this slice. Evidence is
recorded in `artifacts/qa/app-profile-final-verification.json`.

The remaining checkboxes above are deliberately open: this checkpoint exposes the
API but does not yet wire the paced app fixture, run decoded worker transitions,
or qualify automatic resolution adaptation. The next slice adds an explicitly
selected DEBUG simulator fixture with bounded three-phase format evidence and two
validated receipts, runs it through the direct local recorder, and checks the
independent 1080p archive before pressure/recovery work.
