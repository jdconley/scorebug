#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>

// MPEG-TS null packets, identical to the shape used by FFmpeg's muxer.
inline std::array<uint8_t, 1316> nullMessage() {
    std::array<uint8_t, 1316> data;
    data.fill(0xff);
    for (size_t i = 0; i < data.size(); i += 188) {
        data[i] = 0x47; data[i+1] = 0x1f; data[i+3] = 0x10;
    }
    return data;
}
struct TransportCounts { uint64_t packets = 0, nullPackets = 0; };
inline TransportCounts transportCounts(const uint8_t* data, size_t size) {
    if (!size || size % 188) throw std::runtime_error("TS packet alignment");
    TransportCounts counts;
    for (size_t i = 0; i < size; i += 188) {
        if (data[i] != 0x47 || (data[i+1] & 0x80) || !(data[i+3] & 0x30))
            throw std::runtime_error("TS header invalid");
        counts.packets++;
        if ((data[i+1] & 0x1f) == 0x1f && data[i+2] == 0xff) counts.nullPackets++;
    }
    return counts;
}
struct PaddingStats {
    double at, rttMs, bufferMs;
    uint64_t retransmittedBytes, droppedPackets;
};
// Single-owner, one-attempt lease. This meters padding, never media or admission.
class PaddingLease {
    uint32_t rate_;
    double began_, last_, deadline_, tokenAt_, tokens_ = 0, statsAt_;
    double lastAcceptedAt_ = 0;
    uint64_t retransmitted_, dropped_, bytes_ = 0;
    bool reserved_ = false;
    std::string reason_;
    bool stop(const char* reason) { reason_ = reason; tokens_ = 0; reserved_ = false; return false; }
    bool tick(double at) {
        if (!reason_.empty()) return false;
        if (!std::isfinite(at) || at < last_) return stop("invalid-time");
        last_ = at;
        if (at - began_ >= 60) return stop("time-budget");
        if (at >= deadline_) return stop("lease-expired");
        if (bytes_ + 1316 > 16 * 1024 * 1024) return stop("byte-budget");
        return true;
    }
public:
    PaddingLease(uint32_t rate, double at, uint64_t retransmitted, uint64_t dropped)
        : rate_(rate), began_(at), last_(at), deadline_(at + .3), tokenAt_(at), statsAt_(at),
          retransmitted_(retransmitted), dropped_(dropped) {
        if (!rate || rate > 2'000'000 || !std::isfinite(at) || at < 0)
            throw std::runtime_error("padding configuration");
    }
    void renew(double at) { if (tick(at)) deadline_ = at + .3; }
    bool ready(double at, const PaddingStats& stats) {
        reserved_ = false;
        if (!tick(at)) return false;
        if (!std::isfinite(stats.at) || stats.at > at || stats.at < statsAt_ || at - stats.at > .1 ||
            !std::isfinite(stats.rttMs) || stats.rttMs < 0 ||
            !std::isfinite(stats.bufferMs) || stats.bufferMs < 0 ||
            stats.retransmittedBytes < retransmitted_ || stats.droppedPackets < dropped_)
            return stop("invalid-or-stale-statistics");
        statsAt_ = stats.at;
        if (stats.rttMs > 50 || stats.bufferMs > 50 ||
            stats.retransmittedBytes > retransmitted_ || stats.droppedPackets > dropped_)
            return stop("transport-pressure");
        tokens_ = std::min(1360.0, tokens_ + (at - tokenAt_) * rate_ / 8);
        tokenAt_ = at;
        reserved_ = tokens_ >= 1360;
        return reserved_;
    }
    void accepted(double at) {
        if (!reserved_ || !reason_.empty() || !std::isfinite(at) || at < last_)
            throw std::runtime_error("unreserved padding acceptance");
        tokens_ -= 1360; bytes_ += 1316; reserved_ = false; last_ = lastAcceptedAt_ = at;
    }
    const std::string& reason() const { return reason_; }
    uint64_t payloadBytes() const { return bytes_; }
    double deadline() const { return deadline_; }
    double lastAcceptedAt() const { return lastAcceptedAt_; }
};
