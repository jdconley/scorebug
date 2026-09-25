# Stable native capture setup

Goal: allow an idle user to edit the saved proxy/server reliably. Background control polls currently toggle `controlBusy`, disable the form, and dismiss editing even when no recording or durable recovery work remains. An offline endpoint stretches each lock to the bounded 20-second request limit.

Design: track setup-sheet presentation as transient model state. Route only the scheduled control loop through a wrapper that restores state, then skips starting a new request when setup is open, capture is idle and the existing `canChangeSetup` guard is already true. An in-flight operation must settle before editing becomes available. Keep explicit Connect/Retry, durable outboxes, publisher/capture guards and worker-status ownership checks intact. Sheet dismissal resumes background control polling.

- [x] Add focused failing tests for idle pause/resume, in-flight settlement, explicit actions and pending/capture recovery.
- [x] Implement the model wrapper, sheet presentation lifecycle and scheduled-loop call site.
- [x] Pass focused model verification and independent specification/quality reviews.
- [x] Rebuild/install while the phone is idle and verify editing an existing connection and the real phone vertical.

This change must not erase pending work, clear credentials, cancel a recording, relax transport security, or retry mutations automatically. Put commands, failures and device evidence in the session log.
