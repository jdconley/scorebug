# Worker publication association

An optional `publication` on native media status connects the current worker
observation to the relay reader's selected source, the authorized native publishing
attempt and that source's observed clock origin. It supplies identity and coordinates,
not delivery, freshness, loss rate or available capacity. Adaptive quality remains
disabled until matching source intervals and capacity evidence are qualified.

## Identity path

Each actual worker pipeline start creates a fresh random UUID. The worker adds
`sbw1=<UUID>` to the production SRT read stream ID and keeps its control assignment
URL unchanged. Score updates therefore preserve the running read and its identity;
retries get a new identity. Unsupported/legacy URLs still run without association.
The supervisor stops reporting the ID when the pipeline stops or no longer owns
an active observation.

The worker reporter sends `pipelineReadId` at the top level of the authenticated
private report, only after the API session advertises
`pipelineReadIdentity: 'srt-read-query-v1'`. It always removes that private field
from the observation object. An API session remembers each attempt's established
ID through omission, rejects replacement within that attempt, and rejects reuse
by a later attempt. Omission leaves association unknown for the current report.
A new reporting session can associate an already-running pipeline, but its public
workerEpoch changes; retired sessions cannot submit reports.

This uses the existing worker authentication and assignment-specific encrypted
SRT read capability. The query is private correlation data, not a second access
control mechanism. Workers are trusted to report their own pipeline honestly, just
as they are for decoder counters. The public status does not contain the read query,
signed publishing query, credentials, private reporting session or timing tokens.

## Relay lookup and asynchronous scope

For a fresh starting/producing-output report, the API takes its internal scope:
match, broadcast generation, selected worker, public workerEpoch, pipeline attempt
and private read ID. The private relay lookup is bounded to one complete page of
100 connections, 256 KiB and the adapter timeout. Malformed inventories, unsupported
relay builds, ambiguous matches, redirects and failures leave association unknown.
Diagnostic lookups neither provision paths nor queue behind relay control mutations.

The API matches the exact reader query and authorized path, then follows the
reader's captured `scorebugReaderSource`. It requires that publisher's canonical
UUID, same path, publish state and observed ingress clock. It verifies the publisher's
`sbp1` HMAC against the selected ingest path and installation secret. A current-path
source lookup cannot replace this reader-source evidence.

After I/O, the API rechecks the broadcast selection and obtains fresh reporting
status. It exposes metadata only if the reporting scope is unchanged. A new report
within the same pipeline may advance; a new attempt, session, stopped pipeline,
expired report or changed assignment prevents the older result from being attached.
The publisher may end after the snapshot. This association does not claim that it
is still delivering frames.

The additive public shape is:

```json
{
    "publication": {
        "readerId": "<relay reader UUID>",
        "publisherId": "<relay publisher UUID>",
        "publishingAttemptId": "<signed native attempt UUID>",
        "clock": {
            "convention": "mpegts-ingress-origin-90k-v1",
            "originPTS": "9000"
        }
    }
}
```

The example origin is illustrative; production uses the observed value. The native
`validatedPublication` accessor checks canonical identity, exact clock convention,
canonical 33-bit decimal PTS, valid worker/match scope, matching observation and
positive bounded generation/attempt. Malformed optional publication data leaves
ordinary native status usable. Consumers must separately apply
`WorkerStatusFreshness` and match the native publishing attempt before using the
coordinates. Neither identifier equality nor structural validation proves freshness.

## Local qualification

The owned native fixture explicitly selects clock-v2 only with this opt-in; regular
local/deployment configurations retain their existing image selection:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 \
  SCOREBUG_TEST_STREAM_HOLD_SECONDS=30 \
  SCOREBUG_TEST_RELAY_PUBLICATION=1 pnpm test:native-streaming
```

It resolves the local image tag to an immutable image ID before launch. Independent
fixture code compares real API publication metadata with private reader/source/origin
metadata and a separately verified native HMAC/path. It requires at least two distinct
valid decoded-video windows attached to one worker publication, then matches that
association to the native exported recording/match/generation/attempt. It persists
only sanitized identities and clock coordinates. Sequential observations can miss a
connection during teardown; such samples do not count as qualified evidence.

The existing clean archive, live-picture continuity, A/V, score-overlay, post-stream
recording, terminal process and cleanup checks remain required. The finite simulator
fixture does not qualify physical camera/radio behavior, arbitrary reconnect history,
NVIDIA hardware or remote cloud deployment.

## Verified results (2026-09-15)

The maintained full iPhone 14/iOS 17.5 simulator run is
`artifacts/qa/native-app-B3S2kF`, using clock-v2 image
`sha256:f72a43ddbb1db4c027fb935b210b45485cc052a08e7f8e9c04f745d059c7a490`.
Eight distinct completed decoder windows (1–8) share one real worker read and
reporting epoch. The actual publisher's observed origin is **10919** ticks; it is
verified against private relay evidence, not supplied as a fixture constant.

| Identity                  | Observed value                         |
| ------------------------- | -------------------------------------- |
| Worker epoch              | `f9b42899-779f-46ea-930b-6a78937ca937` |
| Pipeline attempt          | 1                                      |
| Reader                    | `999cb436-808b-451f-8495-0587a59d1a38` |
| Publisher                 | `07df22a0-74e1-4857-bc8a-624247576545` |
| Native publishing attempt | `db31b8f0-4153-413d-91bc-b17cb048cf64` |

The archive retains 1,876 pictures (0–1875, 62.533 seconds), and live output retains
1,465 acquired pictures (228–1692, 48.833 seconds). Both have 30 fresh fps and zero
loss inside their measured intervals. The 60 encoded startup pictures before live
acquisition are explicit; the encoded tail is complete. Native scoring changes the
live overlay, recording continues after live stop, and both A/V files fully decode.
Maximum A/V marker offsets are 0.021 ms archive / 64.583 ms live; track-end separations
are 14.667 ms / 7.429 ms. Worker and recorder exit 0. The encoder receives the requested
SIGTERM and exits 255; the existing terminal gate accepts that intentional shutdown,
with complete decoder EOF and saved output evidence. It is not reported as an exit-0
encoder. Exact owned simulator and container absence are independently checked.

An earlier run, `native-app-4Ved1t`, failed waiting for the app to enter publishing.
Its UI tap was recorded, but no broadcast command reached the API; the worker stayed
idle while the local recorder continued writing segments. The preserved data does
not distinguish a disabled-button timing race from other missed-input behavior.
The subsequent final-source run passes. No UI gate was relaxed, and this intermittent
startup observation is retained as an unresolved reliability investigation rather
than attributed to the publication metadata or claimed fixed. Both runs cleaned up
their owned resources.

Follow-up: the poll/action overlap was separately reproduced in a controlled
model test and fixed by synchronous, recording-scoped start intent. The full
native workflow then passed in `native-app-8uryKd`; see
[the start-intent plan](superpowers/plans/2026-09-15-native-start-intent.md).
This establishes the model fix without retroactively proving the cause of the
earlier simulator input failure.

API tests pass 355, worker tests 220, tooling tests 611, and native Core tests 254.
The ten native publication tests include exact malformed scope, optional decode,
clock boundaries and mutation checks. Four valid shared fixture rows also pass
through authenticated API routes with the server-generated worker epoch. The
watchOS 10 arm64_32 Core build and combined unsigned iPhone/embedded Watch Release
build pass. Independent specification and quality reviews
approve the final source. Source hashes, red/green logs and runtime evidence are
retained in `artifacts/qa/worker-publication-final-verification.json`.

The final software-worker recovery command also passes with the production read-ID
changes against the stock relay (association stays unknown there). It verifies worker
SIGKILL/replacement, API outage lease and restart, source loss/recovery, unchanged
encoder during score updates and match-end stop while recording remains active.
Source recovery takes 7,402 ms, below its 10-second bound; recovered clips contain
30 fps moving video and audio. Evidence is preserved in
`artifacts/qa/worker-publication-software-recovery` (moved from the command's fixed
`native-worker-software` output directory after terminal success). These tests check
recovery/control and epoch behavior; the clock-v2 publication media run above checks
the actual association. They do not claim physical radio or arbitrary reconnect
history coverage.
