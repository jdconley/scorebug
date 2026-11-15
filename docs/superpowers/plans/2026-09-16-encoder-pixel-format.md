# Encoder input pixel-format correction

The next native diagnosis found `VideoCodec.makeImageBufferAttributes` using
`inputFormat.mediaType.rawValue` for `kCVPixelBufferPixelFormatTypeKey`. The former
is the general video media type (`vide`), whereas the pixel-buffer attribute needs
the actual pixel format. A format description made from a raw image buffer stores
that code in its media subtype. The existing NV12 fixture therefore describes an
incorrect encoder input format even before rate control is considered.

Correct this independently verifiable defect before adding encoder parameters or
changing the workload. This is a narrowly scoped production setup correction, not
a claim that it explains the previously measured bitrate mismatch. Preserve all
old evidence. Keep automatic adaptation disabled until actual media qualifies.

- [x] Add a regression at the actual session factory boundary with raw NV12 video
      range, NV12 full range and BGRA sample buffers. Prove the current value is
      wrong before changing production code; preserve no-format behavior.
- [x] Use the media subtype for compression input attributes. Regenerate the
      maintained vendor patch and verify original hashes and exact round trip.
- [x] Run the SDK regressions and native Mac average-only low-latency experiment
      against the corrected source. Preserve native errors and complete coverage
      requirements. Then rerun the controlled Mac rate comparison to measure the
      fix's effect on actual cost, regardless of the low-latency outcome.
- [x] Build the original simulator diagnostic and app targets; run relevant
      streaming/tooling tests. Record the result and next evidence-driven action.

The session-factory test inspects the real sample format without creating a native
encoder, so it isolates the setup error from hardware support. Actual diagnostic
runs then test its effect on native encoding. The alternative of adding callback
instrumentation first would leave this known-invalid input attribute in place.

## Evidence

The red test observed `1986618469` (`vide`) instead of each requested raw pixel
format: NV12 video range `875704438`, NV12 full range `875704422`, and BGRA
`1111970369`. The correction uses `CMFormatDescriptionGetMediaSubType` from the
actual input sample. No-format behavior remains nil. All 201 SDK tests pass, and
the maintained patch verifies all 162 original hashes and an exact round trip.

Native Mac average-only run `encoder-native-mac-average-only-XCuViG` still fails
with `codecFailed(status: -1)` after one retained low-latency frame. The default
comparison preserves 601 frames. This fix does not solve the low-latency failure.

Controlled native run `encoder-native-mac-Wwn97w` qualifies all 2,402 frames. Every
frame's compressed byte count matches the retained pre-fix baseline; measured phase
means remain 6.0077, 5.6591, 5.9996 and 4.9356 Mbps. The default native encoder was
therefore insensitive to the incorrect input attribute in this experiment. The
independent audit agrees and rejects 10 damaged variants. The low-rate mismatch
remains unresolved; no requested-rate or network-capacity claim follows.

Actual native simulator run `native-app-H73kCA` passes the full fixed360 pressure
scenario with a separate 1080p archive: 6,448 consecutive archive frames, 6,043
consecutive retained live frames (192 through 6,234), all 107 archive/100 live audio
markers, clean complete decodes, and 29.8 fps minimum reported receiver cadence.
The constrained phase lasts 59,999.951 ms and carries 29,256,712 wire bytes without
proxy drops. Eight native video-cost windows peak at 3,546,668 bps. This preserves
the finite working recording/publishing/scoring path, not automatic adaptation.

The streaming package's 79 tests and tooling suite's 1,195 tests pass. The simulator
diagnostic target builds. The combined unsigned iPhone/Watch Release build passes. The independent media
verifier accepts the unchanged run and rejects all 11 damaged variants. All native
process owners joined; the low-latency failure is retained as a failed experiment.
Evidence and source hashes are frozen in
`artifacts/qa/pixel-format-final-verification-v2.json`.

Next, qualify a genuinely cheaper low-resolution candidate on the same workload;
smaller nominal dimensions alone did not make 360p cheaper than 540p. The exact
low-latency callback cause is also unresolved. Preserve the user-required startup
at minimum, rapid reset and gradual recovery as the delivery target; no production
automatic adaptation or physical-device qualification is claimed by this fix.
