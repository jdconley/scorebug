#include "mpegts-padding.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <vector>

template<class F> static void rejects(F fn) {
    bool rejected = false;
    try { fn(); } catch (const std::exception&) { rejected = true; }
    assert(rejected);
}
static PaddingStats healthy(double at) { return {at, 2, 0, 10, 2}; }
int main() {
    const auto bytes = nullMessage();
    assert(bytes.size() == 1316);
    for (size_t i = 0; i < bytes.size(); i += 188) {
        assert(bytes[i] == 0x47 && bytes[i+1] == 0x1f && bytes[i+2] == 0xff && bytes[i+3] == 0x10);
        for (size_t j = 4; j < 188; j++) assert(bytes[i+j] == 0xff);
    }
    auto counts = transportCounts(bytes.data(), bytes.size());
    assert(counts.packets == 7 && counts.nullPackets == 7);
    auto mixed = bytes; mixed[1] = 1; mixed[2] = 0;
    counts = transportCounts(mixed.data(), mixed.size());
    assert(counts.packets == 7 && counts.nullPackets == 6);
    rejects([&] { transportCounts(bytes.data(), 187); });
    rejects([&] { transportCounts(bytes.data(), 0); });
    mixed[188] = 0; rejects([&] { transportCounts(mixed.data(), mixed.size()); });
    mixed = bytes; mixed[1] |= 0x80; rejects([&] { transportCounts(mixed.data(), mixed.size()); });
    mixed = bytes; mixed[3] = 0; rejects([&] { transportCounts(mixed.data(), mixed.size()); });

    PaddingLease lease(1'000'000, 10, 10, 2);
    assert(!lease.ready(10, healthy(10))); // No startup burst.
    assert(lease.ready(10.02, healthy(10.02)));
    lease.accepted(10.02);
    assert(lease.payloadBytes() == 1316);
    assert(lease.lastAcceptedAt() == 10.02 && lease.deadline() == 10.3);
    assert(!lease.ready(10.02, healthy(10.02)));
    lease.renew(10.1);
    assert(lease.deadline() == 10.1 + .3);
    assert(lease.ready(10.3, healthy(10.3)));
    lease.accepted(10.3); // A stalled loop gets just one message, no catch-up burst.
    assert(!lease.ready(10.3, healthy(10.3)));
    assert(!lease.ready(10.401, healthy(10.401)));
    assert(lease.reason() == "lease-expired");
    lease.renew(10.41);
    assert(!lease.ready(10.42, healthy(10.42)));
    assert(lease.payloadBytes() == 1316 * 2);
    rejects([&] { lease.accepted(10.42); });

    PaddingLease late(1'000'000, 0, 10, 2);
    late.renew(.301); // A renewal must itself enforce expiry.
    assert(late.deadline() == .3);
    assert(late.reason() == "lease-expired");
    assert(!late.ready(.31, healthy(.31)));
    PaddingLease edge(1'000'000, 0, 10, 2);
    assert(!edge.ready(.3, healthy(.3)));
    assert(edge.reason() == "lease-expired");

    for (int scenario = 0; scenario < 8; scenario++) {
        PaddingLease p(1'000'000, 1, 10, 2);
        auto s = healthy(1.1);
        if (scenario == 0) s.rttMs = 50.01;
        if (scenario == 1) s.bufferMs = 50.01;
        if (scenario == 2) s.retransmittedBytes++;
        if (scenario == 3) s.droppedPackets++;
        if (scenario == 4) s.at = .99;
        if (scenario == 5) s.at = 1.11;
        if (scenario == 6) s.retransmittedBytes--;
        if (scenario == 7) s.rttMs = std::numeric_limits<double>::quiet_NaN();
        assert(!p.ready(1.1, s));
        assert(!p.reason().empty());
        assert(!p.ready(1.11, healthy(1.11)));
    }
    PaddingLease budget(2'000'000, 0, 10, 2);
    double t = 0;
    while (budget.reason().empty()) {
        t += .006;
        budget.renew(t);
        if (budget.ready(t, healthy(t))) budget.accepted(t);
    }
    // Time budget wins at this rate before 16 MiB; both are hard upper bounds.
    assert(budget.reason() == "time-budget");
    assert(budget.payloadBytes() <= 16 * 1024 * 1024);
    assert(t < 60.01);
    for (auto rate : {0u, 2'000'001u}) rejects([&] { PaddingLease p(rate, 0, 0, 0); });
    rejects([] { PaddingLease p(1, -1, 0, 0); });
    PaddingLease reversed(1'000'000, 10, 10, 2);
    assert(!reversed.ready(9, healthy(9)));
    assert(reversed.reason() == "invalid-time");
    std::cout << "MPEG-TS padding and lease assertions passed\n";
}
