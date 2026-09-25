# Device vertical implementation

User-authorized scope: run native iPhone recording/streaming/scoring and paired Watch scoring against a local proxy, with both a mock RTMP destination MP4 and a proxy overlay MP4. Both apps are signed, installed and launch using the selected Conley Chaos LLC team; physical workflow acceptance remains open. Do not change existing simulator-only assertions or use camera fixtures on hardware.

- [x] Add a bounded local device-lab launcher: explicit assigned private LAN IPv4, isolated database, random development credentials, owned relay container, loopback-only management and RTMP receiver, native worker with both outputs. Save private setup details and retain media; join all owned processes on shutdown.
- [x] Check argument rejection, real startup/readiness and cleanup, then document native UI setup and exact output locations.
- [x] Exercise the existing native simulator streaming test against the new proxy output mode and decode all outputs.
- [x] Sign/install and launch the phone and Watch apps using the selected team.
- [ ] Run physical camera + clean archive + native scoring + proxy + both MP4s. Exercise the paired Watch during phone capture.
- [ ] Record outcomes in session logs and fix concrete vertical failures before continuing adaptive research.

The lab is a development tool; it does not publish to YouTube. Binding an assigned LAN address exposes the authenticated scoring API and encrypted SRT media only to the selected interface. It retains the phone archive separately. Process startup is readiness, not media acceptance.
