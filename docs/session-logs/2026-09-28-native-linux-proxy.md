# September 28 — native capture through Linux proxy

Startinga89d765, clean. Previous turn fixed Linux image timing capability. This
turn connects that image to the existing native lab, without duplicating UI tests.

Added container-lab-worker.mjs and --worker-image on device-lab, headless native
and manual simulator launchers. Adapter is explicitly for Mac Docker Desktop;
production Linux/home/cloud config remains in the worker runbook. It uses existing
compiled image (no pull), private envfile, only state/recording bind mounts, CPU
encoder and actual timing readiness. Mac loopback URLs become host.docker.internal;
LAN URLs are preserved. Shutdown stops/inspects/removes only its named container,
joins the attached process and retains its logs/recordings. Container crash is a
separate qualification, rejected before lab resource allocation.

Focused `node --test scripts/test/device-lab-options.test.mjs`:10passed,
55966 exit0. Includes unchanged defaults, scope/secret/path mapping and invalid
image/backend rejection. Syntax/diff checks passed. No broad suite.

One native network integration command (scoped Xcode26.2):
`node scripts/test-headless-streaming.mjs --host 192.168.1.130 --source
/Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov
--duration 120 --quality 1080 --timing-audit off --worker-encoder software
--worker-image scorebug/home-daemon:qa-timing-trixie`.
67041 exit0. Artifact`headless-native-wJYttO`,lab`device-lab-0tavVM`.
Native export reuses existing bundle; adapted existing final-media verifier only
changes required resolution from2160to1080 and scope text.45761 exit0.

## Result

API registration, SRT reader, Linux software overlay, actual mock RTMP destination
and optional proxy recording work. Normal native policy confirms360p at71s;
receiver logs1467frames240p then2080frames360p with exact3000/90000PTS steps.
Archive62segments/3628consecutive frames0–3627; both1080p outputs3547matching source
frames62–3608. All3MP4s fully decode with zero video/audio gaps, audibleRMS>0.10,
exact30fps within MP4/RTMP timestamp precision. A/V ends: archive25.33ms,
mock12.07ms,proxy1.57ms. Archive continues19frames beyond live. Container worker
exits0 without force; bothcleanup lists empty; Docker ps empty.

linux-integration-acceptance.json binds current adapter/harness/config/diagnostic,
worker log, cleanup, media verifier/report/hashes and worker image ID. This is a
120s local Linuxarm64 Docker integration, staticoverlay and first adaptive climb;
not full ladder, fullmatch, actual remote Linux/NVIDIA/amd64, radios or fresh UI
acceptance. Dynamic native scoring retains separate prior evidence.

No lab/test jobs active. Manual simulators remain preserved. Reuse this result
for unchanged code; next work stays in open plan gates, not another startup test.
