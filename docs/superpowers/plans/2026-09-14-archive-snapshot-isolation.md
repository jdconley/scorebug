# Isolate archive status reads from disk persistence

Use subagent-driven development for the bounded implementation and independent
specification and quality reviews. Reuse existing agents when capacity prevents
fresh workers. Work only in the existing local-validation worktree.

The ten-minute failure shows a half-second persistence/append overlap. Source
inspection identifies a separate, concrete lock dependency: status snapshots hold
the writer lifecycle lock while waiting for the segment store's disk-operation
lock. Remove that dependency without changing native lifecycle serialization,
segment durability, queue budgets, capture pacing, or encoding profiles.

- [ ] Add a deterministic failing regression. A gated segment read must not prevent
  a competing writer operation from acquiring its lock. Use an internal segment-read
  dependency seam if needed to establish ordering; thread-start signals or sleeps
  cannot prove lock entry. Preserve a real store persistence gate integration test.
- [ ] Capture writer scalar/lifecycle state under its short lock, release that lock,
  then read committed segments. Document that these fields are not an atomic
  cross-component snapshot; a finished state must never accompany an earlier
  incomplete segment list. Add a scalar accepted-duration accessor for periodic
  Film health polling so that duration reads do not query committed segment storage.
- [ ] Observe red/green; verify duration progression and storage failure behavior,
  snapshot semantics, cancellation/finalization races and synchronous durability.
  Run full Media and Film suites, then independent spec and quality reviews.
- [ ] Record evidence and commit the reviewed fix. Run an isolated short native
  workflow, then the 600-second hold if the short run passes. Retain and analyze any
  failure without weakening a gate. Passing a deterministic lock regression alone
  does not prove all native persistence stalls have been eliminated.

If the native stall persists, distinguish writer-lock acquisition, native readiness
and append, and persistence phases with bounded diagnostics before choosing another
fix. Asynchronous persistence would require its own bounded queue, failure semantics
and finish barrier; it is outside this focused change. Motion-heavy fixtures and
physical-device tests remain necessary after basic recording reliability improves.
