# Replacement latency breakdown — September 26

Previous turn made progress: committed the bounded successful-transition audit, passed 82 Swift and 39 Node tests plus signed/Release builds, and retained a fresh complete 720p media failure with the first descent captured. Worktree starts clean at c0e7de2. All prior jobs are joined; goal active.

Read the native replacement path before adding observers. `SRTStream.runVideoReplacement` joins the old drain, commits the replacement, and then permits raw input to the new encoder. Existing standalone native traces already retain the exact new encoder submission/completion and first compressed output. Preliminary four-run inspection places first submission about 42 ms after request; first completion follows 27–30 ms later on the host and 430–432 ms later in the simulator. This bounds all work before first submission but is not a direct drain measurement.

Checked Haivision's current primary socket-option documentation while investigating whether transport pacing was omitted. Repository history contains the explicit relative sender-pacing experiment of September 16: measured native pacing, reduced bursts, but failed live cadence and identity checks. Do not rediscover that failed experiment as a new fix. See `docs/superpowers/plans/2026-09-16-relative-sender-pacing.md` and https://github.com/Haivision/srt/blob/master/docs/API/API-socket-options.md#srto_maxbw .

Selected offline strict breakdown instead of new capture instrumentation. User's autonomous implementation authorization remains in force. Design and remaining hardware tasks are in the replacement-latency plan; no new permission gate.
