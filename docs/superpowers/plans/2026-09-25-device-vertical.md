# Device vertical implementation

User-authorized scope: run native iPhone recording/streaming/scoring and paired Watch scoring against a local proxy, with both a mock RTMP destination MP4 and a proxy overlay MP4. Physical signing awaits the owner's team choice. Do not change existing simulator-only assertions or use camera fixtures on hardware.

- [ ] Add a bounded local device-lab launcher: explicit assigned private LAN IPv4, isolated database, random development credentials, owned relay container, loopback-only management and RTMP receiver, native worker with both outputs. Save private setup details and retain media; join all owned processes on shutdown.
- [ ] Check argument rejection, real startup/readiness and cleanup, then document native UI setup and exact output locations.
- [ ] Exercise the existing native simulator streaming test against the new proxy output mode and decode all outputs.
- [ ] Sign/install the phone and Watch apps after the team is chosen; run camera + clean archive + native scoring + proxy + both MP4s. Exercise the Watch during phone capture.
- [ ] Record outcomes in session logs and fix concrete vertical failures before continuing adaptive research.

The lab is a development tool; it does not publish to YouTube. Binding an assigned LAN address exposes the authenticated scoring API and encrypted SRT media only to the selected interface. It retains the phone archive separately. Process startup is readiness, not media acceptance.
