# September 28 — hands-on simulator launch

Starting `723b8f5`, clean. Previous turn made production progress on worker-loss
pipe ownership. This turn makes the already implemented apps directly usable
without running another automated vertical. No app production behavior changed.

Added `scripts/simulator-lab.mjs`: uses existing device lab, incremental Xcode
builds, simulator fixture capture and scoped Watch offer. Creates two iPhone14
simulators and a paired Series7 41mm, boots/installs/opens apps, starts loopback
API plus LAN SRT/software proxy/mock RTMP recorder. Phone Score fields use existing
Debug prefill; Film configuration is entered manually from private setup.json.
Watch presents Join offered match, with normal user acceptance and direct HTTP.

Default camera is synthetic A/V. Optional absolute --source is hashed and copied
using the existing verified staging helper; original files remain unchanged.
Credentials stay in private lab files and launch environment, not argv/logs.
Existing process-group command runner handles build interruption/timeouts. Backend
is bounded by --duration or Ctrl-C; simulators and app containers remain for
recording export/recovery. It deliberately never deletes someone’s recordings.
Each launch is a fresh session; guide explains retained-device cleanup ownership.

## Check

`node --check scripts/simulator-lab.mjs` passed. Ran exactly one startup check:
`node scripts/simulator-lab.mjs --host 192.168.1.130 --duration 5`.
Artifact `artifacts/qa/manual-simulators-qiL8sA`, lab `device-lab-XEnHSX`.
Builds, installs and all three launches passed; ready event emitted, then backend
finished normally. Process15891 joined0; shutdown.json has worker exit0, no forced
kill, finished receiver and failures[]. No recording was started.

Screenshots via simctl: camera displays Ready to record with synthetic input;
Watch displays Join offered match (acceptance is manual, not silently automated).
Screenshot process47582 joined0. Screenshots retained under the manual artifact.
No full suite, UI automation, media replay or physical device testing.
This proves launcher startup/cleanup, not a fresh feature/media qualification;
reuse prior acceptance for those. Optional source staging was not rerun because
it delegates unchanged to the existing tested staging/capture path.

README/fast-iteration guide/plan/handoff updated. Diff whitespace checked.
No lab/test jobs active. Three explicitly named manual simulators remain booted,
with IDs/container paths in devices.json. Backend is stopped after the five-second
check. Next product engineering remains live crash-tail and unsupported backend
work; do not repeat unchanged acceptance or this startup check without changes.
