# Live-platform research — September 25, 2026

User requested published practices from Facebook, Instagram, TikTok, YouTube and comparable broadcasters before more timing work. Started at `2a2c684` in the local-validation worktree.

Read primary Meta engineering, YouTube help, ByteDance's SIGCOMM 2026 abstract, OBS source/guidance, Haivision SRT documentation, Apple VideoToolbox samples and AWS IVS documentation. Findings, links, scope limits and proposed comparisons are in [the research note](../research/2026-09-25-live-platform-adaptation.md). ACM full-text retrieval failed; only the official conference abstract supports the TikTok summary. No detailed current Instagram mobile-upload controller was found. Viewer-side BytePlus/Reels/RTC material is not substituted for it.

Main implication: the 1.5-second internal deadline is a project benchmark, not a public-platform requirement. Define a reliability-first stage budget and compare explicit 2/3-second ingest profiles before attempting to remove more recovery buffer. Retain the old failed evidence and all media-integrity gates. Numeric changes remain proposals; code and runtime settings are unchanged.

Validation: documentation diff/relative links checked. No native or media tests rerun for this research-only change. Current recordings and reviewed code remain at the preceding checkpoint. Next work starts with the revised timing objective, coordinated phone/Watch acceptance, and then an explicitly versioned experimental comparison.
