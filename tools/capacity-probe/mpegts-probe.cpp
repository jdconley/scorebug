// Finite loopback MPEG-TS replay laboratory. No native-app admission policy.
#include "mpegts-padding.h"
#include <srt/srt.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <thread>
#include <vector>

static volatile sig_atomic_t interrupted = 0;
static void interrupt(int) { interrupted = 1; }
static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static void fail(const std::string& message) { throw std::runtime_error(message); }
static void check(int result, const char* label) { if (result == SRT_ERROR) fail(std::string(label) + ": " + srt_getlasterror_str()); }
static uint32_t number(const std::string& value) {
    if (value.empty() || value.size() > 10 || value.find_first_not_of("0123456789") != std::string::npos) fail("invalid integer");
    const auto n = std::stoull(value); if (n > UINT32_MAX) fail("integer range"); return uint32_t(n);
}
struct Socket {
    SRTSOCKET id = SRT_INVALID_SOCK;
    ~Socket() { close(); }
    void close() { if (id != SRT_INVALID_SOCK) { srt_close(id); id = SRT_INVALID_SOCK; } }
};
struct Runtime { Runtime() { check(srt_startup(), "startup"); } ~Runtime() { srt_cleanup(); } };
struct File { int id; ~File() { if (id >= 0) ::close(id); } };
template<class T> static void option(SRTSOCKET id, SRT_SOCKOPT key, T value) { check(srt_setsockflag(id, key, &value, sizeof value), "option"); }
static std::vector<uint8_t> readSource(const char* path) {
    File file{open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)};
    struct stat info{};
    if (file.id < 0 || fstat(file.id, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 16 * 1024 * 1024) fail("source file bound/type");
    std::vector<uint8_t> bytes(size_t(info.st_size)); size_t at = 0;
    while (at < bytes.size()) {
        auto n = read(file.id, bytes.data() + at, bytes.size() - at);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) fail("source read"); at += size_t(n);
    }
    transportCounts(bytes.data(), bytes.size());
    return bytes;
}
static void save(const char* path, const std::vector<uint8_t>& bytes) {
    File file{open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)};
    if (file.id < 0) fail("output create");
    size_t at = 0;
    while (at < bytes.size()) {
        auto n = write(file.id, bytes.data() + at, bytes.size() - at);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) fail("output write"); at += size_t(n);
    }
    if (fsync(file.id)) fail("output sync");
}
int main(int argc, char** argv) {
    std::cout << std::setprecision(12); std::cout.setf(std::ios::unitbuf);
    signal(SIGINT, interrupt); signal(SIGTERM, interrupt); signal(SIGPIPE, SIG_IGN);
    try {
        for (int fd : {STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO}) {
            int flags = fcntl(fd, F_GETFL);
            if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) fail("pipe flags");
        }
        std::cout.exceptions(std::ios::badbit | std::ios::failbit);
        if (argc < 5) fail("sender PORT RUN_ID SOURCE EXPECTED | receiver PORT RUN_ID OUTPUT");
        const bool sender = std::string(argv[1]) == "sender";
        if ((sender && argc != 6) || (!sender && (argc != 5 || std::string(argv[1]) != "receiver"))) fail("role/arguments");
        const uint32_t port = number(argv[2]), run = number(argv[3]);
        if (!port || port > 65535 || !run) fail("port/run bounds");
        const std::string streamID = "scorebug-ts-probe-" + std::to_string(run);
        const auto source = sender ? readSource(argv[4]) : std::vector<uint8_t>{};
        std::vector<uint8_t> accepted; accepted.reserve(32 * 1024 * 1024);
        TransportCounts counts;
        size_t sourceAt = 0; uint64_t messages = 0;
        bool stop = false, started = false, sourceEnded = false;
        double startedAt = 0, reportAt = 0;
        std::unique_ptr<PaddingLease> padding;
        std::string reportedReason;
        {
            Runtime runtime;
            if (srt_getversion() != SRT_VERSION_VALUE) fail("SRT header/runtime version mismatch");
            Socket socket, listener; socket.id = srt_create_socket(); check(socket.id, "socket");
            option(socket.id, SRTO_TRANSTYPE, SRTT_LIVE);
            option(socket.id, SRTO_RCVSYN, false); option(socket.id, SRTO_SNDSYN, false);
            option(socket.id, SRTO_LATENCY, 120); option(socket.id, SRTO_CONNTIMEO, 2000);
            option(socket.id, SRTO_LINGER, linger{1, 1});
            if (sender) {
                option(socket.id, SRTO_SENDER, true); option(socket.id, SRTO_MAXBW, int64_t(0));
                check(srt_setsockflag(socket.id, SRTO_STREAMID, streamID.data(), int(streamID.size())), "stream id");
            }
            sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(uint16_t(port)); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            const double began = now();
            if (sender) {
                int result = srt_connect(socket.id, reinterpret_cast<sockaddr*>(&address), sizeof address);
                if (result == SRT_ERROR && srt_getlasterror(nullptr) != SRT_EASYNCSND) check(result, "connect");
                while (srt_getsockstate(socket.id) != SRTS_CONNECTED) {
                    if (interrupted || now() - began > 5 || srt_getsockstate(socket.id) >= SRTS_BROKEN) fail("connect deadline/state");
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
            } else {
                check(srt_bind(socket.id, reinterpret_cast<sockaddr*>(&address), sizeof address), "bind"); check(srt_listen(socket.id, 1), "listen");
                std::cout << "{\"kind\":\"listening\",\"at\":" << now() << "}\n";
                listener.id = socket.id; socket.id = SRT_INVALID_SOCK;
                while (socket.id == SRT_INVALID_SOCK) {
                    socket.id = srt_accept(listener.id, nullptr, nullptr);
                    if (socket.id == SRT_INVALID_SOCK && srt_getlasterror(nullptr) != SRT_EASYNCRCV) fail("accept");
                    if (interrupted || now() - began > 8) fail("accept deadline");
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                listener.close();
                char id[128]{}; int length = sizeof id;
                check(srt_getsockflag(socket.id, SRTO_STREAMID, id, &length), "read stream id");
                if (length < 0 || length > int(sizeof id) || std::string(id, size_t(length)) != streamID) fail("connection identity mismatch");
                option(socket.id, SRTO_RCVSYN, false); option(socket.id, SRTO_SNDSYN, false);
            }
            std::cout << "{\"kind\":\"ready\",\"at\":" << now() << ",\"runID\":" << run << ",\"version\":\"" << SRT_VERSION_STRING << "\"}\n";
            std::string pending; unsigned commands = 0; PaddingStats pressure{}; SRT_TRACEBSTATS stats{};
            const auto nulls = nullMessage();
            auto record = [&](const uint8_t* data, size_t size) {
                if (size > 32 * 1024 * 1024 - accepted.size()) fail("capture memory bound");
                const auto value = transportCounts(data, size);
                counts.packets += value.packets; counts.nullPackets += value.nullPackets;
                accepted.insert(accepted.end(), data, data + size); messages++;
            };
            auto send = [&](const uint8_t* data, size_t size) {
                int n = srt_sendmsg(socket.id, reinterpret_cast<const char*>(data), int(size), -1, true);
                if (n == SRT_ERROR) { if (srt_getlasterror(nullptr) != SRT_EASYNCSND) fail("send"); return false; }
                if (n != int(size)) fail("partial message"); record(data, size); return true;
            };
            while (!stop && !interrupted) {
                if (now() - began > 30) fail("native lifetime bound");
                char input[1024]; ssize_t n = read(STDIN_FILENO, input, sizeof input);
                if (!n) fail("stdin closed without stop");
                if (n > 0) pending.append(input, size_t(n));
                else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) fail("stdin read");
                if (pending.size() > 4096) fail("command buffer bound");
                size_t newline;
                while ((newline = pending.find('\n')) != std::string::npos) {
                    const auto line = pending.substr(0, newline); pending.erase(0, newline + 1);
                    if (++commands > 2048) fail("command count bound");
                    std::istringstream words(line); std::string kind, rate, extra; words >> kind;
                    if (kind == "stop" && !(words >> extra)) { stop = true; break; }
                    if (sender && kind == "start" && !started && !(words >> extra)) { started = true; startedAt = now(); continue; }
                    if (sender && kind == "probe" && started && !sourceEnded && !padding && (words >> rate) && !(words >> extra)) {
                        const double at = now(); check(srt_bstats(socket.id, &stats, 0), "probe baseline statistics");
                        padding = std::make_unique<PaddingLease>(number(rate), at, stats.byteRetransTotal, stats.pktSndDropTotal);
                        pressure = {at, stats.msRTT, double(stats.msSndBuf), stats.byteRetransTotal, uint64_t(stats.pktSndDropTotal)};
                        std::cout << "{\"kind\":\"probe-start\",\"at\":" << at << ",\"rateBps\":" << number(rate) << ",\"deadline\":" << padding->deadline()
                            << ",\"retransmittedBytes\":" << pressure.retransmittedBytes << ",\"droppedPackets\":" << pressure.droppedPackets
                            << ",\"sourceBytes\":" << sourceAt << ",\"transportBytes\":" << accepted.size() << ",\"probeBytes\":0}\n"; continue;
                    }
                    if (sender && kind == "lease" && padding && !(words >> extra)) {
                        const double at = now(); padding->renew(at);
                        std::cout << "{\"kind\":\"lease\",\"at\":" << at << ",\"deadline\":" << padding->deadline()
                            << ",\"renewed\":" << (padding->reason().empty() ? "true" : "false") << "}\n"; continue;
                    }
                    fail("invalid command");
                }
                if (stop) break;
                const double at = now();
                if (at - pressure.at >= .05) {
                    check(srt_bstats(socket.id, &stats, 0), "statistics");
                    pressure = {at, stats.msRTT, double(stats.msSndBuf), stats.byteRetransTotal, uint64_t(stats.pktSndDropTotal)};
                }
                if (sender) {
                    // Source byte clock assumes this fixture's documented constant mux rate.
                    const bool mediaDue = started && sourceAt < source.size() && at - startedAt >= double(sourceAt) * 8 / 3'500'000;
                    if (mediaDue) {
                        const size_t bytes = std::min(size_t(1316), source.size() - sourceAt);
                        if (send(source.data() + sourceAt, bytes)) sourceAt += bytes;
                    }
                    // Always evaluate withdrawal, including iterations occupied by media.
                    if (padding && padding->ready(now(), pressure) && !mediaDue && !sourceEnded) {
                        // Evidence timestamps actual acceptance completion, not send entry.
                        // If preempted across expiry, the independent lease proof must reject it.
                        if (send(nulls.data(), nulls.size())) padding->accepted(now());
                    }
                    if (padding && padding->reason() != reportedReason) {
                        reportedReason = padding->reason();
                        std::cout << "{\"kind\":\"withdrawn\",\"at\":" << now() << ",\"reason\":\"" << reportedReason << "\",\"sourceBytes\":" << sourceAt << ",\"probeBytes\":" << padding->payloadBytes()
                            << ",\"transportBytes\":" << accepted.size() << ",\"deadline\":" << padding->deadline() << ",\"lastAcceptedAt\":" << padding->lastAcceptedAt()
                            << ",\"statisticsAt\":" << pressure.at << ",\"rttMs\":" << pressure.rttMs << ",\"bufferMs\":" << pressure.bufferMs
                            << ",\"retransmittedBytes\":" << pressure.retransmittedBytes << ",\"droppedPackets\":" << pressure.droppedPackets << "}\n";
                    }
                    if (started && !sourceEnded && sourceAt == source.size()) {
                        sourceEnded = true;
                        std::cout << "{\"kind\":\"source-ended\",\"at\":" << now() << "}\n";
                    }
                } else {
                    for (unsigned work = 0; work < 256; work++) {
                        uint8_t data[1500]; const int received = srt_recvmsg(socket.id, reinterpret_cast<char*>(data), sizeof data);
                        if (received == SRT_ERROR) { if (srt_getlasterror(nullptr) != SRT_EASYNCRCV) fail("receive"); break; }
                        record(data, size_t(received));
                    }
                }
                if (at - reportAt >= .05) {
                    reportAt = at;
                    std::cout << "{\"kind\":\"sample\",\"at\":" << now() << ",\"sourceBytes\":" << sourceAt << ",\"transportBytes\":" << accepted.size()
                        << ",\"messages\":" << messages << ",\"packets\":" << counts.packets << ",\"nullPackets\":" << counts.nullPackets
                        << ",\"probeBytes\":" << (padding ? padding->payloadBytes() : 0) << ",\"rttMs\":" << stats.msRTT << ",\"bufferMs\":" << stats.msSndBuf
                        << ",\"retransmittedBytes\":" << stats.byteRetransTotal << ",\"droppedPackets\":" << stats.pktSndDropTotal << "}\n";
                }
                std::this_thread::sleep_for(std::chrono::microseconds(500));
            }
            socket.close(); listener.close();
        }
        save(argv[sender ? 5 : 4], accepted);
        std::cout << "{\"kind\":\"finished\",\"at\":" << now() << ",\"requestedStop\":" << (stop ? "true" : "false")
            << ",\"transportBytes\":" << accepted.size() << ",\"sourceBytes\":" << sourceAt << ",\"probeBytes\":" << (padding ? padding->payloadBytes() : 0) << "}\n";
        return stop ? 0 : 2;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
