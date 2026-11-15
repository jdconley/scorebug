# Native bandwidth estimate qualification

**Goal:** Establish whether the actual SRT packet-pair bandwidth estimate is useful for upward quality admission. The prior paced trial still produced 7.85 Mbps of video on a 4 Mbps constrained link. Healthy delivery at the lower profile does not prove spare capacity for the higher profile.

## Contract

The adapter already reads `mbpsBandwidth` into validated `PublishingTransportStatistics.estimatedBandwidthMbps`. Export that value with its actual collection timestamp in existing bounded DEBUG evidence. Do not add a new sampler, change encoding or transport behavior, or derive usable capacity from it. Zero remains zero; historical evidence without this diagnostic stays readable. Present malformed values must fail independent verification.

[SRT's statistics documentation](https://github.com/Haivision/srt/blob/master/docs/API/statistics.md#mbpsbandwidth) describes an estimate based on receiver packet-pair timing returned in ACKs. This is distinct from the sender pacing ceiling and successful application delivery. The installed GoSRT receiver computes an exponentially weighted average of packet-pair arrival measurements. Host scheduling and the local impairment proxy may affect that estimate; the controlled link rate is only an independent test reference, never input to production decisions.

## Work

- [x] Add regression tests for actual value/timestamp preservation, zero, malformed diagnostics, historical compatibility and unchanged pressure decisions.
- [x] Retain the existing estimate in native diagnostic JSON and validate it independently.
- [x] Run relevant tooling and app-model tests. Snapshot source before native measurement.
- [x] Repeat the preceding 240-second paced experiment with identical settings. Compare estimates during unconstrained, 4 Mbps and recovered phases, including the upward trial; keep all existing media failures.
- [x] Join owners, verify cleanup and source provenance, document whether this gauge can safely admit upgrades, and commit the checkpoint.

The production adaptation gate remains closed. No phone/Watch/remote-host qualification is implied. Use Xcode 26.2, existing build directories and sequential heavy workloads. Do not copy large media unnecessarily.

Pre-run validation: 213 app-model tests and 1026 tooling tests pass. Causal red tests demonstrated the missing JSON value and missing malformed-value checks. Review of the four source/test changes confirms the estimate is diagnostic only, retains its actual timestamp, and neither adds sampling nor changes controller decisions. Historical fixtures still pass.

## Next admission design boundary

The existing `capacityQualified` policy requires caller-supplied usable **video** capacity; the opt-in profile-trial policy allows a higher profile when capacity is unknown. Neither requested encoder bitrate nor the packet-pair estimate can fill that gap. The next experiment should measure bounded additional delivered traffic on the publishing path while keeping the current video profile and independent archive running. It needs explicit byte/rate/duration bounds, cancellation and cleanup, fresh receiver feedback, and immediate withdrawal on queue, RTT, loss, or media pressure. It must not change resolution merely to discover that the candidate does not fit.

First qualify the probe in the local harness against separately controlled rate changes and competing traffic. Keep the impairment rate out of the application/controller. Account for actual video payload, audio, framing and recovery overhead; report unknown when these observations do not establish headroom. Compare any admission against measured candidate encoder cost, including transition bursts, rather than the nominal requested rate. Preserve a way to discover improved conditions later: permanently disabling upgrades does not satisfy the quality requirement. Any proposed probe must demonstrate that it preserves recording, picture identity, A/V coverage and the 24 fps floor before production integration.

## Measured result and decision

Source was snapshotted against `f5fb149` before native run `native-app-NxygNl`. Its saved configuration exactly matches the preceding `native-app-xJ7FLN`: source-cadence pacing, relative sender pacing, actual 400 ms publishing delay, slice decoding, and the 240-second adaptive rate4m fixture. No new behavior flag is involved. The UI workflow passes. The full runner fails live A/V end coverage at **−230.3 ms** against the unchanged 100 ms limit; supplemental media qualification also fails picture identity and cadence.

The **1004** distinct native samples preserve actual estimate values and agree on repeated reads. Native elapsed-time increments track collection uptime. Estimates range from **8.412 to 9253.956 Mbps**, median **6270 Mbps** over the publication. Interior socket-age bands give:

| Approximate test phase | Socket age | Samples | Minimum / median / maximum estimate, Mbps |
| ---------------------- | ---------: | ------: | ----------------------------------------: |
| Unconstrained          |    10–50 s |     157 |            3650.352 / 6515.820 / 9253.956 |
| 4 Mbps constraint      |   70–110 s |     157 |              41.184 / 5560.392 / 7408.020 |
| Recovered              |  140–220 s |     313 |            3565.032 / 6670.692 / 8833.704 |

The proxy independently confirms its rate changes at 60.0005 and 120.0012 seconds after its first packet. Socket creation and that packet are **not an independently measured cross-clock anchor**; these interior bands are approximate phase alignment, not exact event/packet correspondence. The native sample covering the failed upward trial reports **6177.684 Mbps**, observed only **250.6 ms** before admission. The recovered trial's latest estimate is **6148.068 Mbps**, 193.2 ms old. Freshness does not make these gauges usable capacity. No filter or multiplier is qualified to turn them into admission evidence.

Other unchanged checks:

- Archive: **8200 consecutive 1080p/30 frames**, 273.333 seconds, **136/136 audio markers**, 9.33 ms end offset and zero rejected/dropped queue samples.
- Native output: **7824** consecutive frame records across five phases, actual source-cadence pacing on every record. Maximum consumer wait is 60.48 ms, maximum scheduled source lead 32.86 ms; suspension scheduling can wake after eligibility. All **85** local pressure windows replay. Four native applications complete in **462–478 ms**, within their two-second budgets. Median accepted source-evidence age is **1.653 seconds**, maximum 1.789, within the unchanged two-second limit.
- Live: **7654** decoded pictures, **176 absent unique identities**, **66 repeated observations**, **45 non-increasing barcodes** and 68 identity/cadence anomalies. Worst receiver window is **15 fps**. Positive audio-PTS gaps total 256.3 ms. The worker records 390 decoder-error messages; these are not damaged-frame counts.
- Both **2623-bin** proxy timelines reconcile without omissions. Forward overflow is **867 packets**, maximum residence 527.37 ms; reverse overflow is zero. Partial relay snapshots retain the same publishing/read connection identities and confirm the 400/120 ms leg delays.

**Decision:** Retain `estimatedBandwidthMbps` as diagnostic evidence only. It is unsuitable for approving quality increases in this local simulator/proxy/relay setup, including at the exact native admission boundary. Do not generalize this measurement into a claim about all physical SRT networks. Production adaptation remains disabled, and source-cadence pacing remains opt-in. Proceed with the bounded-probe design boundary above rather than feeding this estimate into `usableVideoCapacity` or repeating an unqualified large profile jump.

1239 relevant tests pass (213 app-model and 1026 tooling). Native, closed-evidence collector and supplemental media-analysis owners are terminal and joined. Finalization verifies exact simulator/container removal, stopped collection, runtime source equality to the snapshot, and identical stopped/final quality evidence before hashing terminal artifacts. Evidence is under `artifacts/qa/bandwidth-estimate-*` and the native run directory. Approximately 12 GiB remains; preserve existing evidence and avoid unnecessary media/build duplication. Physical phone/Watch, other hosts, long soaks and production readiness remain open.
