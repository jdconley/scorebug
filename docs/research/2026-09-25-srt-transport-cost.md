# SRT transport-cost accounting

Research date: September 25, 2026. This refines production admission design; it does not change runtime behavior or qualify a network path.

## Verified source behavior

The bundled SRT version is1.5.4. Its [`CUDT::bstats`](https://github.com/Haivision/srt/blob/v1.5.4/srtcore/core.cpp#L6868-L6973) adds one fixed header allowance per data packet when calculating sent/received/unique/retransmitted byte counters. `mbpsSendRate` uses those adjusted bytes. This is library accounting, not a measurement of all bytes on the physical link.

The allowance comes from [`CPacket`](https://github.com/Haivision/srt/blob/v1.5.4/srtcore/packet.h#L341-L350):16bytes of SRT header and28bytes for IPv4 plus UDP. No socket-family selection occurs in that calculation. Consequently, treating this counter as an exact IPv6 wire count would be incorrect.

A local test against the actual bundled1.5.4 library confirms this on both loopback families:12messages of188/376/1316bytes,7520payload bytes,8048reported unique bytes in each case (`7520 + 12 × 44`). Both receivers obtained all12messages. Processes joined with exit0. Source, executable and library hashes and raw outputs are retained under `artifacts/qa/srt-ip-accounting-20260925/`. This tests counter semantics; it is not a packet capture or a mobile-network qualification.

The base IPv6 header is40bytes; extension headers can add more ([RFC8200, sections3–4](https://www.rfc-editor.org/rfc/rfc8200.html#section-3)). UDP's header is8bytes ([RFC768](https://www.rfc-editor.org/rfc/rfc768.html)). With the SRT data header, ordinary unfragmented IPv6 therefore has64bytes of base overhead per data packet, compared with44for ordinary IPv4. These totals exclude link framing, extensions/options, fragmentation, tunnels, control messages and retransmissions.

## Scorebug's current measurement boundary

`PublishingCandidateAdmission.laboratoryIPv4` costs complete measured candidate MPEG-TS bytes plus44bytes per transport message. It divides by the shorter of source and submission duration, then compares against the lower delivered padding rate from two receiver intervals. Core requires padding rate at least1.25times candidate cost. The current stream continues during probing, so this tests additional delivered load while the existing stream is present.

Candidate transport messages can be188–1316bytes. Probe messages are1316bytes; the receiver conservatively subtracts TS packets already pending at the beginning of an interval. Equal payload rates therefore need not mean equal per-packet overhead. The candidate includes audio/muxing, not just the configured H.264 bitrate.

The44byte model is explicitly a laboratory convention. Neither this value nor SRT's fixed44byte statistics should silently become a generic mobile-path guarantee.

## Production direction

Use an explicitly named transport-load estimate, measured candidate packetization, delivered same-path padding, reserved headroom and current queue/recovery/media feedback. A64byte base-header allowance is conservative for ordinary unfragmented IPv4 and covers ordinary unfragmented IPv6. It is a model, not a universal upper bound on Wi-Fi, cellular or VPN wire cost. Do not claim otherwise or compensate with an unexplained arbitrary constant.

The next implementation must keep the laboratory44byte route unchanged, make production costing explicit, and test short/full TS messages, audio inclusion, finite bounds and IPv4/IPv6 accounting. Probing should target the next supported candidate profile, not inherit the laboratory12Mbps final stage. Candidate cost remains a measured value; a nominal bitrate estimate only chooses initial probe load and cannot authorize an increase.

Retain the current recovery-pressure guards and delivery checks. Validate ordinary IPv4/IPv6 paths and constrained links locally, then Wi-Fi/cellular behavior on the phone. A route change or worsening delivery must cause fresh measurement or a downshift; a prior estimate does not establish lasting capacity. Exact outer-link accounting is not required for a practical adaptive controller, but the scope of its estimate must be honest.

See [platform adaptation research](2026-09-25-live-platform-adaptation.md) for published sender-feedback patterns and the distinction between platform guidance and Scorebug's experimental timing policy.
