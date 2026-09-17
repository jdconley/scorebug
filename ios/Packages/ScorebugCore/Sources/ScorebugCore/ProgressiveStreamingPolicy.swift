/// Initial Scorebug qualification values, not universal streaming standards.
/// These operate on independently qualified source-delivery measurements; raw
/// packet loss or decoder arrival bursts are not missing/late source frames.
public enum ProgressiveStreamingPolicy {
    public static let minimumDecoderStallDuration = 1.0
    public static let maximumDecoderStallSampleAge = 0.25
    public static let freshFrameFloor = 24.0
    public static let healthyFrameRate = 29.7
    public static let minimumLossWindowDuration = 2.0
    public static let maximumLossFraction = 0.05
    public static let maximumHealthyLossFraction = 0.01
    public static let healthyIncreaseDuration = 4.0
    public static let recoveryDurations = [10.0, 20.0, 40.0, 60.0]
}
