# Bounded capacity probe implementation plan

> **For agentic workers:** Use superpowers:executing-plans for this authorized continuation in the existing isolated worktree.

**Goal:** Measure bounded extra delivered traffic on one real local SRT connection before integrating upward video admission.

**Architecture:** A small native SRT sender/receiver supplies actual counters and pressure. A pure Node policy controls only additional load; an owned runner applies independent rate changes, records evidence and joins all resources. No production or archive code changes.

**Tech stack:** C++17, installed SRT via pkg-config, Node built-ins, existing UDP impairment proxy.

## Tasks

- [x] Write `scripts/test/capacity-probe-policy.test.mjs` around `new CapacityProbePolicy({baselineBps, targetBps, stepBps, startedAt})`, `observe({now,sender,receiver})`, and `cancel(now)`. Assert no advance with stale, old-stage, short, loss, pressure or underdelivered evidence; assert bounded ramp, rejection and success. Run `node --test scripts/test/capacity-probe-policy.test.mjs` and retain the causal failure.
- [x] Implement `scripts/capacity-probe-policy.mjs` with validated scalar observations, matching-stage monotonic counters, per-stage 1.5-second delivery proof, 300-ms freshness, 50-ms pressure ceilings and 60-second/16-MiB bounds. Return explicit `set`, `qualified`, `refused`, or `cancelled` decisions. Rerun the focused tests.
- [x] Implement `tools/capacity-probe/srt-probe.cpp`. Compile with `c++ -std=c++17` and installed `pkg-config --cflags --libs srt` output into an ignored artifact directory. Accept only `sender PORT RUN_ID` or `receiver PORT RUN_ID`. Commands are `ping ID`, `set STAGE BASE_BPS PROBE_BPS`, `lease STAGE`, and `stop`; reject malformed/range-invalid input. Read stdin and SRT nonblocking, cap per-loop work and total lifetime, retain actual library version, then close all sockets before terminal output.
- [x] Implement `scripts/test-capacity-probe.mjs`, with bounded child stdout/stderr, request/response clock bridges, independent rate scheduling, fixed baseline and policy-driven extra load. On terminal attempt, explicitly reset extra load to zero. Retry later with a fresh policy on the same connection. Always cancel timers, close/join exact owned children/proxy, and persist failure evidence.
- [x] Run `pnpm test:tools`, compile with warnings enabled, and execute `node scripts/test-capacity-probe.mjs`. Inspect actual received baseline/extra bytes, pressure, clock bounds, stage decisions, proxy conservation and terminal ownership; keep any failed outcome explicit.
- [x] Review and document the transport result and remaining native-video/competing-flow gates. Hash terminal evidence and changed source; commit the checkpoint without enabling production adaptation.

Use no large media copies or new Apple build directories: available disk is about 12 GiB. Execute locally and sequentially. The caller's existing autonomous authorization covers this reversible experiment; no deployment or external broadcast occurs.

The implementation also extracts bounded child-process ownership into `scripts/capacity-probe-process.mjs` with four real process fault/stop tests. All 1061 tooling tests pass, including 35 new policy/ownership tests. Review found a previous-stage loss-report hole and missing readable-pipe error handlers; causal regressions reproduce both, and targeted re-review confirms both fixes. New attempts retain explicit cumulative counter baselines; new discontinuities still withdraw immediately.

Native observations now include sticky total message/discontinuity counters, and the final harness drains until all accepted baseline and probe messages are delivered. A measured baseline warm-up prevents the SRT startup RTT from being mistaken for constrained-link pressure. The earlier startup-only refusal is retained as an invalid experiment, not capacity evidence. A deliberate lease-renewal interruption verifies native probe withdrawal while baseline continues. Source snapshots and initial/final clock bridges accompany the authoritative run.

## Authoritative transport outcome

`capacity-probe-4sg89u` is the final reviewed run. Installed SRT 1.5.6 agrees between headers and the loaded runtime. All seven runtime sources match the saved snapshot. The measured baseline is **3.488 Mbps** of accounted message traffic. The controller receives no proxy configuration.

On the independently constrained 4 Mbps path, 3.75 and 4.0 Mbps stages complete their receiver windows. The next **4.25 Mbps** offered step withdraws when the actual sender reports **50.419 ms RTT** and a 26 ms send buffer. This is active-probe pressure, after baseline warm-up, not the initial SRT RTT default. Following the independent 12 Mbps recovery, a fresh ramp reaches a **6 Mbps** offered load and delivers **5.989 Mbps** over its final **1.508-second** receiver window.

All **11,302 baseline messages** and **2,781 probe messages** arrive with **zero missing or duplicated identities** after a bounded drain. The probe consumes **3,659,796 payload bytes**, below its 16 MiB bound. Native sent bytes equal accepted messages times 1360 bytes, with zero retransmitted bytes, corroborating this fixture's 44-byte per-message header accounting. This does not include control traffic as useful delivery.

The deliberate renewal interruption stops probe messages while **65 further baseline messages** are accepted. Both proxy timelines reconcile over **356 bins** with no omitted events or overflow; maximum forward residence is **63.77 ms**. Initial/final clock bridge uncertainties are 0.40–0.64 ms and their offset intervals agree. Both native children finish on requested stop, exit zero, and are joined; the proxy closes with no pending sends/errors. The independent verifier matches every successful step's endpoints to raw receiver rows, recomputes delivery arithmetic, checks sampled sender pressure, all cumulative counters, complete delivery and unchanged runtime source.

Full tooling tests pass **1061/1061**, including **35** new policy/process tests. The native compiler uses `-Wall -Wextra -Werror`. Earlier prototype outcomes remain in separate artifacts; notably, the initial startup-only refusal is not qualifying evidence. Read-only review fixes and their causal tests are recorded in `artifacts/qa/capacity-probe-review.txt`. Terminal source/evidence hashes accompany this checkpoint.

## Next work

This establishes a bounded transport primitive, not native media readiness. Next evaluate valid MPEG-TS padding or an equivalent probe on the actual publishing SRT connection, with receiver accounting before media demux discards padding. Preserve the current encoded profile and independent archive. Scope feedback to the exact publishing attempt and connection, and retain source collection timestamps. The laboratory's 300 ms IPC freshness limit cannot simply be copied to the existing receiver control path, whose observed evidence age is about 1.65 seconds; separate local pressure/lease renewal from slower, bounded receiver confirmation without relaxing existing media/freshness requirements.

Candidate admission must compare receiver-verified load with actual encoder cost, audio and transport/recovery overhead, including transition bursts. Current simulator high-profile trials have reached about 7.85 Mbps of video alone. A 6 Mbps synthetic qualification is not authorization for that profile. Test competing traffic, feedback delays/loss, sudden capacity reduction, native picture identity/cadence, A/V coverage and the clean archive before enabling any policy. Physical phone/Watch routes, other hosts and long soaks remain open.
