# Milestone 0 results

Validated September 13, 2026 PDT (September 14 UTC), on the M4 Max development Mac.
Implementation branch: `codex/local-validation`.

The repeatable environment and native setup foundation are complete. This is not
a qualification of functional scoring, phone recording, streaming, or Watch.

| Check                                    | Result                                                                                                                                     |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `pnpm typecheck`                         | Passed across the TypeScript workspace                                                                                                     |
| `pnpm test`                              | 24 Vitest tests and 7 tool-runner tests passed; protocol has a no-op test script and legacy PWA has no tests                               |
| `pnpm build` / `pnpm format:check`       | Passed                                                                                                                                     |
| `pnpm run doctor` with scoped Xcode 26.2 | All required prerequisites passed; watchOS 11 runtime reported as a later coverage warning                                                 |
| Real encoder probes                      | Full FFmpeg 8.1.2 encoded six frames with drawtext using VideoToolbox with software fallback disabled, and separately libx264              |
| Configured overlay paths                 | Real FFmpeg filter execution passed with spaces, apostrophes, colon, comma, and brackets in font/score paths                               |
| `pnpm test:container`                    | Final image started, health returned expected state, unauthenticated game access returned 401, owned resources removed                     |
| `pnpm test:local`                        | Separate pinned ingest/sink configs started and exposed fixture paths; anonymous management requests returned 401; owned resources removed |
| `pnpm dev:api`                           | Bound loopback port 18787 and returned `{"ok":true,"home":false}`; stopped after check                                                     |
| Shared native core                       | 6 XCTest cases passed                                                                                                                      |
| Unsigned generic iPhone build            | Passed with deployment minimum iOS 17.0                                                                                                    |
| Native setup UI                          | XCUITest passed on iOS 17.5 and 26.2; final 26.2 run repeated after aligning API port                                                      |
| Independent reviews                      | Native specification review and overall code-quality review passed after cleanup fixes                                                     |

Regression tests were observed failing before fixes for missing container runtime
dependencies, configured worker tools, doctor false positives, failed-start
cleanup, and cancellation teardown. Cleanup failure is also covered: successful
HTTP checks cannot turn a failed container removal into a passing run.

The selected Xcode is scoped through `DEVELOPER_DIR`; the global selection was
not changed. Default Xcode 26.6 needs its missing iOS 26.5 platform component
repaired before it can be used for this harness. XcodeGen 2.46 was installed.
Node 25.9.0 and pnpm 9.15.0 were used for final local checks; CI specifies Node 22.
The updated CI jobs have been exercised locally but have not run on GitHub yet.

Apple evidence remains in ignored `ios/build/`:

- iOS 17.5: `scoring-df6bf0ed-9dce-4ae0-b141-5af5c0d30fec.xcresult`
- Final iOS 26.2: `scoring-848122ae-8710-4839-9b6d-b6cb70d48d66.xcresult`
- Final build/test log: `artifacts/qa/apple-final.log` at the repository root

The runners removed their own containers and simulators. Manual fixture volumes
persist when using `local:down`; automated smoke volumes are removed. No external
broadcast or remote worker deployment was started.

Next: [milestone 1](superpowers/plans/2026-09-13-portable-streaming-and-watch.md#milestone-1-durable-match-identity-and-native-iphone-scoring),
starting with the [recovery regression requirements](regression-baseline.md).
See the [runbook](local-testing.md) for fresh-checkout commands and later device gates.
