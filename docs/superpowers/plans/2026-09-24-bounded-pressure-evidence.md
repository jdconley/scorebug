# Bounded pressure evidence implementation plan

> Use superpowers:executing-plans. The user has authorized autonomous implementation and routine design decisions.

**Goal:** Preserve independently replayable pressure evidence during sustained congestion without exceeding the existing 8 MiB quality-file limit.

**Architecture:** Recovery-policy exports use quality format 6 with a versioned dictionary of unique thermal samples, transport samples and queue states. Each event stores canonical consecutive index ranges in place of copied arrays. A boundary decoder reconstructs format 5 histories, preserving every scalar, order and event before existing policy validators run. Legacy exports remain format 4; historical format 5 remains readable.

**Tech stack:** Swift/Foundation, Node/assert, XCTest and existing replay fixtures.

The failed recorded export contains 27,354 thermal, 27,293 transport and 57,574 queue entries, but only 459/458/264 unique entries respectively. Plain index references reduce 17,126,924 bytes to about 1.45 MB; ranges further reduce repeated contiguous references. This is a storage experiment, not a requalification of the failed run.

Alternatives: dropping old histories would remove replay evidence; compressing the whole JSON would retain repeated object storage and require separate decompression bounds. The dictionary retains the complete evidence with explicit limits. No pressure thresholds, FPS criteria, admission rights, network settings or parser limits change.

## Contract

- Only explicit recovery-policy exports change to format 6. Root transport policy stays `recovery-budget-v1`. Dictionary format is 1 with exactly `thermal`, `transport`, `queue` tables and `formatVersion`.
- Evidence histories replace `samples` with `sampleRanges`, or `states` with `stateRanges`. Each history also declares `sampleCount` or `stateCount` so truncated ranges cannot silently shorten it. Each range is `[start,count]`; adjacent ranges that can merge are invalid. Empty histories use empty ranges. Null queue remains null.
- Intern exact scalar dictionaries in first-reference order, per table; no duplicate entries, unused entries, future/out-of-bounds references or mixed inline/reference histories. Decoded values are immutable shared copies; do not mutate the raw artifact.
- At most 512 events, 64 thermal/transport items per history, 4,096 queue states, and 65,536 unique items per table. Entries have at most 32 scalar fields, bounded key/string lengths. Numeric values use finite IEEE doubles within the safe-integer magnitude bound; signed zero normalizes to zero, booleans stay distinct and large integer counters remain strings. Mutable Foundation strings are copied into owned UTF-8 Swift values. The aggregate serialized entry/event budget is 7 MiB, leaving headroom below the unchanged 8 MiB file limit. On overflow/encoding failure, roll back the incomplete row and mark export overflow; never silently drop evidence and still qualify.
- Native storage retains pooled rows, not the old full histories. Existing live/final immutable checkpoint semantics and joined shutdown remain intact. No work runs on capture callbacks.
- Host decoding occurs at artifact/whole-trial boundaries. Existing lower-level validators continue to require canonical format 5 (or historical 4). Unsupported versions, corruption, truncation and overflow fail closed.

## Steps

- [x] Write codec malformed-reference, exact-roundtrip and bounded-storage tests; observe red.
- [x] Implement Swift bounded dictionary store and host decoder. Verify canonical first-use ordering and overflow rollback.
- [x] Wire recovery export, harness reads and whole-trial replay; retain legacy defaults and existing policy gates.
- [x] Cross-language roundtrip real oversized diagnostic data; compare every original event/history and byte size. This is storage verification only.
- [x] Run focused/full app-model and tooling suites, independent review, and commit verified checkpoint.
- [ ] Exercise a fresh sustained-pressure native export before claiming that long impaired media workflows pass. Continue causal capacity/outage, production integration, wider profiles and physical Watch work afterward.

## Verification checkpoint

Behavioral red/green logs cover host decoding, Swift interning, recovery driver format selection, whole-trial integration and mutable Foundation string/signed-zero defects. All 542 app-model tests pass. The whole-trial test reconstructs the same synthetic recovery input and obtains the identical complete qualification; wrong policy and corrupted sender-drop evidence still fail. These fixtures are not new network evidence.

The real Swift writer processed all 479 events of the prior 17,126,924-byte pressure export in 0.838 s aggregate, producing 1,087,736 bytes. Host decoding deep-compared every event/history with the original. Legacy header metadata was explicitly remapped for this storage-only experiment, without claiming recovery-policy qualification. The actual recovery-policy export from `native-app-NCUMkX` also round-trips exactly: 25 events, 274,811 encoded bytes. Sources/output/assessment reside in `artifacts/qa/pressure-dictionary-cross-language/`.

Read-only review found a mutable-scalar alias (reproduced and fixed) and a missing brace in the harness loading loop (fixed). All 3,879 tooling tests also pass. A fresh native format6 export is next. Live repeated-recovery defaults remain legacy format4; this change does not enable the separately unqualified recovery-budget repeated route.

The next frozen native run keeps the existing static impaired-link fixture to exercise the new writer, artifact loading loop and independent replay boundaries. It is needed for format6 integration, not another attempt to get favorable strict30fps counts. Sustained-pressure capacity/outage routing remains a separate next gate.

## Fresh native format6 checkpoint

`native-app-YFObMQ`, frozen by `pressure-dictionary-freeze-7tvso5i0`, ran the unchanged static 30 ms/0.2% loss route with the real match source. The UI workflow passed in 170.244 s. Export format6 is 257,350 bytes, 24 events, overflow false; host expansion and full component/policy replay work. Candidate measurement completes 121 inputs and applies240p→360p. Archive IDs0–3881 and live230–3667 are consecutive; clean archive continues7.13s after live. Baseline and27 phase audio anchors pass for each output, as do score glyph checks; audio timeline error is≤0.228ms.

The joined harness exit remains1: one of152 delivery rows is unknown (`freshness`). The other151 meet strict30fps with zero late/missing/uncertain/below24 rows. The unknown receipt was121.322ms old at its earlier cadence evaluation;140.245ms later, the audit correctly rejected its261.567ms conservative age against the unchanged250ms limit. This is missing timely evidence, not proof of dropped media, and must not be counted as healthy. No freshness threshold or classifier was changed.

All1,222 frozen source/input hashes match after join; no temporary simulator is booted and no relay container remains. Separate `failure-assessment.json`, `pressure-dictionary-components.json`, `independent-phase-audio-qualification.json` and `freshness-assessment.json` retain the observations. Original failed artifacts are unchanged. This verifies the live codec/reader path, not sustained-pressure or complete network qualification.

A later fresh run, `native-app-G0kJLr`, passes the complete preselected `floor24-v1` trial with format6 export255,792bytes and154 classified healthy delivery windows. It validates the live codec through successful full-trial and phase-audio replay; sustained-pressure qualification remains open. See the [delivery floor checkpoint](2026-09-24-measured-delivery-floor.md).
