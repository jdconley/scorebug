import SDKProbe
let probe = SDKProbe()
try await probe.configure()
do {
    try await probe.setBitRate(3_000_000)
    preconditionFailure("A live bitrate update requires an active encoder")
} catch SDKProbe.PublisherError.notPublishing {
    // Initial configuration is distinct from a verified live update.
}
_ = await probe.metrics()
await probe.stop()
print("HaishinKit 2.2.5 SRT configure/pre-publish rejection/metrics/stop smoke passed; no capture/network")
