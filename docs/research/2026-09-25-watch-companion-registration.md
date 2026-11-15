# Watch companion registration boundary

## Observed evidence

The paired ordinary simulator attempt `ordinary-native-LhOSEV` reaches the normal 240p→360p increase, but no Watch identity reaches the phone. The owned simulator pair reports active/connected; both app bundles are installed; the phone embeds the Watch app and the Watch companion bundle identifier matches the phone. The Watch session activates and reports reachable, but `isCompanionAppInstalled` is false. Both application-context publication and the one immediate-message probe fail with WCError 7018. No Watch pairing or scoring command is created. Recording continuation, native export and full three-output decoding/frame/audio-timestamp checks pass. The combined workflow remains failed.

This reproduces the boundary retained in earlier `paired-watch-gKwDrj` and `paired-watch-WWMaEj` investigations. An immediate-message setup fallback is not supported by these results. Do not repeat the same full paired experiment without a concrete registration change. If simulator diagnosis remains necessary, isolate it in a minimal independent framework reproducer before changing Scorebug's protocol.

## Primary-source guidance checked September 25, 2026

Apple documents [companionAppNotInstalled](https://developer.apple.com/documentation/watchconnectivity/wcerror/companionappnotinstalled) as the error for a missing companion installation. Its [WCSession documentation](https://developer.apple.com/documentation/WatchConnectivity/WCSession) requires activation before communication and distinguishes installation state from reachability. Correct bundle identifiers and active/reachable state alone therefore do not establish successful communication.

Apple's [Transferring data with Watch Connectivity sample](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity) explicitly directs testing on a physical iPhone and Apple Watch. It also specifies the companion bundle identifier relationship, which matches the retained Scorebug metadata. This is a reason to prioritize hardware acceptance, not proof that every WatchConnectivity API is unsupported in every simulator or that this failure is an Apple defect. No authoritative current simulator-registration fix was established in this research.

## Next verification

- Restore the physical Watch developer connection and run the fresh paired camera/scoring vertical. Automation approval is already granted; the outstanding issue is Xcode's connection/preparation timeout.
- Keep native Watch model/UI and direct-network tests separate from actual paired connectivity qualification.
- Preserve all failed reports and do not inject Watch identity/setup to claim a paired pass.
- Continue independent streaming/fault qualification while hardware readiness is unresolved; simulator registration is not evidence against the passing recording and progressive-streaming checkpoints.
