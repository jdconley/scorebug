# Bounded capacity probe implementation plan

> **For agentic workers:** Use superpowers:executing-plans for this authorized continuation in the existing isolated worktree.

**Goal:** Measure bounded extra delivered traffic on one real local SRT connection before integrating upward video admission.

**Architecture:** A small native SRT sender/receiver supplies actual counters and pressure. A pure Node policy controls only additional load; an owned runner applies independent rate changes, records evidence and joins all resources. No production or archive code changes.

**Tech stack:** C++17, installed SRT via pkg-config, Node built-ins, existing UDP impairment proxy.

## Tasks

- [ ] Write `scripts/test/capacity-probe-policy.test.mjs` around `new CapacityProbePolicy({baselineBps, targetBps, stepBps, startedAt})`, `observe({now,sender,receiver})`, and `cancel(now)`. Assert no advance with stale, old-stage, short, loss, pressure or underdelivered evidence; assert bounded ramp, rejection and success. Run `node --test scripts/test/capacity-probe-policy.test.mjs` and retain the causal failure.
- [ ] Implement `scripts/capacity-probe-policy.mjs` with validated scalar observations, matching-stage monotonic counters, per-stage 1.5-second delivery proof, 300-ms freshness, 50-ms pressure ceilings and 60-second/16-MiB bounds. Return explicit `set`, `qualified`, `refused`, or `cancelled` decisions. Rerun the focused tests.
- [ ] Implement `tools/capacity-probe/srt-probe.cpp`. Compile with `c++ -std=c++17` and installed `pkg-config --cflags --libs srt` output into an ignored artifact directory. Accept only `sender PORT RUN_ID` or `receiver PORT RUN_ID`. Commands are `ping ID`, `set STAGE BASE_BPS PROBE_BPS`, and `stop`; reject malformed/range-invalid input. Read stdin and SRT nonblocking, cap per-loop work and total lifetime, retain actual library version, then close all sockets before terminal output.
- [ ] Implement `scripts/test-capacity-probe.mjs`, with bounded child stdout/stderr, request/response clock bridges, independent rate scheduling, fixed baseline and policy-driven extra load. On terminal attempt, explicitly reset extra load to zero. Retry later with a fresh policy on the same connection. Always cancel timers, close/join exact owned children/proxy, and persist failure evidence.
- [ ] Run `pnpm test:tools`, compile with warnings enabled, and execute `node scripts/test-capacity-probe.mjs`. Inspect actual received baseline/extra bytes, pressure, clock bounds, stage decisions, proxy conservation and terminal ownership; keep any failed outcome explicit.
- [ ] Review and document the transport result and remaining native-video/competing-flow gates. Hash terminal evidence and changed source; commit the checkpoint without enabling production adaptation.

Use no large media copies or new Apple build directories: available disk is about 12 GiB. Execute locally and sequentially. The caller's existing autonomous authorization covers this reversible experiment; no deployment or external broadcast occurs.
