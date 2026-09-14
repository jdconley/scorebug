import SDKProbe
let probe = SDKProbe()
try await probe.configure()
try await probe.setBitRate(3_000_000)
_ = await probe.metrics()
await probe.stop()
print("HaishinKit 2.2.5 SRT configure/bitrate/metrics/stop smoke passed; no capture/network")
