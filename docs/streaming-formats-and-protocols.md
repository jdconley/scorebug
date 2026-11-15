# Encoding and streaming formats

The current media path is:

```text
iPhone camera and microphone
  ├─ H.264 High + AAC → fragmented MP4 local archive → MP4 export
  └─ H.264 High + AAC-LC → MPEG-TS → SRT → streaming proxy
                                               └─ FFmpeg overlay/encoding
                                                   → H.264 + AAC → FLV → RTMP/RTMPS
```

**Video:** H.264/AVC (ITU-T H.264 / ISO/IEC 14496-10). The phone's publishing
recipe requests High Profile with automatic level selection through VideoToolbox,
30 fps, no frame reordering, and a maximum two-second keyframe interval. Requested
bitrate is a target; actual encoded bytes and processing time must be measured.
The local archive has an independent encoder and quality configuration.

**Audio:** AAC. The phone's streaming encoder requests AAC-LC and packages AAC
frames with ADTS headers for transport. The proxy currently encodes AAC at
128 kbps and 44.1 kHz for its output.

**Phone to proxy:** MPEG-2 Transport Stream, carrying the H.264 video and AAC audio,
over SRT (Secure Reliable Transport). MPEG-TS is the packaging format; it does not
mean the video uses the older MPEG-2 video codec. The transport implementation
submits chunks of up to 1,316 bytes, seven 188-byte TS packets. SRT uses UDP and
provides packet-loss recovery. Encryption is a configurable protocol capability,
not an assumption that every development connection is encrypted.

**Proxy to platform:** FFmpeg emits H.264/AAC in FLV through RTMP or RTMPS. RTMPS
adds TLS to the RTMP connection. The proxy can choose an available CPU or supported
hardware encoder while preserving this output format. Portability to additional
machines and GPUs still requires deployment and performance verification.

**Local recording:** The phone writes recoverable fragmented MP4 independently
of the live stream, with clean video and audio. The archive/export path uses
AVAssetWriter and the project's fragment store. Stream quality changes do not
select archive quality.

**Adaptive quality:** This is sender-side adaptive bitrate and resolution control.
The stream starts at the minimum profile and can increase only after fresh encoder
cost, device-pressure and network evidence qualify it. This project currently
keeps production automatic upgrades disabled while qualification is completed.
It does not implement HLS/DASH viewer selection: those are downstream playback
delivery choices for the destination platform. Product thresholds and cooldowns
are policies to verify, not universal settings prescribed by these codecs.

Implementation references: `PublishingVideoProfile.swift`, `AudioCodecSettings.swift`,
`SRTSocket.swift`, `SegmentedArchiveWriter.swift`, and `apps/home-daemon/src/pipeline.ts`.
Standards references: [ITU AVC carriage in MPEG-TS](https://www.itu.int/ITU-T/recommendations/rec.aspx?rec=7208),
[Haivision SRT protocol specification](https://haivision.github.io/srt-rfc/draft-sharabayko-srt.html).
