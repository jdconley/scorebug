# Physical cadence rejection witness

Goal: explain the exact health-report age that resets real-phone quality trials, before changing production freshness thresholds or adaptation behavior.

Evidence: closed per-attempt audits from physical MJj7dD and bUx6EQ show cadenceRejected/freshness resetting 360p trials to 240p after 18.833 seconds and 11.469 seconds, without any injected impairment. The rejection occurs before the decoder-stalled check and can reflect unavailable/invalid report age or age exceeding 250 ms. Later mutable diagnostics do not preserve the rejected receipt's age.

## Scope and invariants

- Add a DEBUG-only immutable diagnostic accessor to WorkerDecoderCadence using existing validated age inputs. Report server age, HTTP duration, local residence, total age or an explicit unavailable reason. Match current freshness predicates; change no release behavior or threshold.
- In the cadence-rejection catch, freeze the witness from the exact original receipt/evaluation clock, synchronously before first-cause latching. Include receipt identity, actual allowed-age limit, consumed/revalidation state and decoder progress fields.
- Bind audit-only witness fields atomically with the existing first-invalidation/revision latch. Snapshot at application admission before suspension. Export only through the existing successful Core-ACK transition audit; later samples/rejections/reset advice cannot replace the first cause.
- Existing attempt/fromRevision ownership, reset replacement semantics, ACK/closure clearing and 16-record / 8,192-byte bounds remain. No witness leaks to another revision, unsuccessful application or the 4,096-byte UI diagnostic.
- Do not invent worker sample time or mix unrelated monotonic clocks. The first decomposition distinguishes server age, HTTP duration and post-response residence; it cannot separately identify probe work versus scheduling without further evidence.

## Work and acceptance

- [x] Implement the accessor and first-cause audit witness after the startup-contract implementation is frozen; keep a single implementation owner at a time.
- [x] Meaningful red→green tests: exact stale receipt during active trial and successful reset ACK; first-cause immutability; delayed admission/ACK; unavailable-age reasons; not-stalled freshness rejection; unsuccessful application/revision isolation; accessor component bounds; unchanged UI and bounded audit sizes.
- [x] Preserve independent audit verification: validate the explicit new audit-only fields and exclude only those fields from the unchanged UI witness comparison. Add a separate physical v3 entry point; the ordinary v2 verifier retains its contract.
- [x] Independent spec/quality reviews and focused tests pass (78 app, 7 Core, 210 Node). Signed Debug phone/Watch and Release builds pass; binary checks confirm Debug presence and Release exclusion. All jobs joined before capture.
- [x] Include the diagnostic in the lit moving-scene physical run and inspect its actual path: no transition applies, so the successful-ACK audit correctly closes with zero records.
- [ ] Exercise and inspect a physical cadence-triggered successful reset before considering freshness-policy changes. The latest no-ramp failure instead needs exact candidate-admission/readiness evidence.

Root owns docs, reviews, builds, physical runs and media collection. This is diagnostic instrumentation, not a recovery fix or permission bypass.
