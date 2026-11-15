// Loopback laboratory only. Fixed baseline and extra messages share one SRT socket.
#include <srt/srt.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <algorithm>

static volatile sig_atomic_t interrupted = 0;
static void interrupt(int) { interrupted = 1; }
static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static void fail(const std::string& message) { throw std::runtime_error(message); }
static void check(int result, const char* label) { if(result == SRT_ERROR) fail(std::string(label)+": "+srt_getlasterror_str()); }
static uint32_t number(const std::string& value) {
    if(value.empty() || value.size()>10 || value.find_first_not_of("0123456789")!=std::string::npos) fail("invalid unsigned integer");
    auto n=std::stoull(value);if(n>UINT32_MAX)fail("integer range");return uint32_t(n);
}
static void put(char* p, uint32_t v) { v=htonl(v);std::memcpy(p,&v,4); }
static uint32_t get(const char* p) { uint32_t v;std::memcpy(&v,p,4);return ntohl(v); }
struct Socket {
    SRTSOCKET id=SRT_INVALID_SOCK;
    ~Socket(){if(id!=SRT_INVALID_SOCK)srt_close(id);}
    void close(){if(id!=SRT_INVALID_SOCK){srt_close(id);id=SRT_INVALID_SOCK;}}
};
struct Runtime { Runtime(){check(srt_startup(),"startup");} ~Runtime(){srt_cleanup();} };
template<class T> static void option(SRTSOCKET id,SRT_SOCKOPT key,T value) { check(srt_setsockflag(id,key,&value,sizeof value),"option"); }
static bool connecting(SRTSOCKET id) {
    auto state=srt_getsockstate(id);
    if(state==SRTS_BROKEN || state==SRTS_CLOSED || state==SRTS_NONEXIST)fail("connection closed");
    return state!=SRTS_CONNECTED;
}
int main(int argc,char** argv) {
    std::cout << std::setprecision(12);std::cout.setf(std::ios::unitbuf);
    signal(SIGINT,interrupt);signal(SIGTERM,interrupt);signal(SIGPIPE,SIG_IGN);
    try {
        // Diagnostic backpressure must fail instead of blocking the probe watchdog.
        for(int fd: {STDOUT_FILENO,STDERR_FILENO}) {
            const int flags=fcntl(fd,F_GETFL);
            if(flags<0||fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0)fail("output flags");
        }
        std::cout.exceptions(std::ios::badbit|std::ios::failbit);
        if(argc!=4)fail("sender|receiver PORT RUN_ID required");
        const std::string role=argv[1];const bool sender=role=="sender";
        if(!sender && role!="receiver")fail("invalid role");
        auto port=number(argv[2]),run=number(argv[3]);if(!port||port>65535||!run)fail("port/run range");
        Runtime runtime;if(srt_getversion()!=SRT_VERSION_VALUE)fail("SRT header/runtime version mismatch");Socket socket,listener;socket.id=srt_create_socket();check(socket.id,"socket");
        option(socket.id,SRTO_TRANSTYPE,SRTT_LIVE);
        option(socket.id,SRTO_RCVSYN,false);option(socket.id,SRTO_SNDSYN,false);
        option(socket.id,SRTO_LATENCY,120);option(socket.id,SRTO_CONNTIMEO,2000);
        linger closeBound{1,1};option(socket.id,SRTO_LINGER,closeBound);
        if(sender){option(socket.id,SRTO_SENDER,true);option(socket.id,SRTO_MAXBW,int64_t(0));}
        sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(uint16_t(port));address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        const double began=now();
        if(sender) {
            const int result=srt_connect(socket.id,reinterpret_cast<sockaddr*>(&address),sizeof address);
            if(result==SRT_ERROR && srt_getlasterror(nullptr)!=SRT_EASYNCSND)check(result,"connect");
            while(connecting(socket.id)) {if(interrupted||now()-began>5)fail("connect deadline");std::this_thread::sleep_for(std::chrono::milliseconds(1));}
        } else {
            check(srt_bind(socket.id,reinterpret_cast<sockaddr*>(&address),sizeof address),"bind");check(srt_listen(socket.id,1),"listen");
            std::cout << "{\"kind\":\"listening\",\"at\":" << now() << "}\n";
            listener.id=socket.id;socket.id=SRT_INVALID_SOCK;
            while(socket.id==SRT_INVALID_SOCK) {
                socket.id=srt_accept(listener.id,nullptr,nullptr);
                if(socket.id==SRT_INVALID_SOCK && srt_getlasterror(nullptr)!=SRT_EASYNCRCV)fail("accept failed");
                if(interrupted||now()-began>8)fail("accept deadline");
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            listener.close();option(socket.id,SRTO_RCVSYN,false);option(socket.id,SRTO_SNDSYN,false);
        }
        const int flags=fcntl(STDIN_FILENO,F_GETFL);if(flags<0||fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK)<0)fail("stdin flags");
        std::cout << "{\"kind\":\"ready\",\"role\":\"" << role << "\",\"version\":\"" << SRT_VERSION_STRING << "\",\"at\":" << now() << "}\n";
        uint32_t stage=0,base=0,probe=0,sequence[2]={0,0},lastSequence[2]={0,0};
        bool seen[2]={false,false},stop=false;uint64_t counts[2]={0,0},totals[2]={0,0},missing=0,duplicates=0,totalMissing=0,totalDuplicates=0,probeBytes=0;
        bool leaseExpired=false,budgetExhausted=false;double leaseDeadline=0;
        double tokens[2]={0,0},previous=now(),reportAt=0;std::string pending;unsigned commands=0;
        while(!stop && !interrupted) {
            const double at=now();if(at-began>90)fail("native lifetime exhausted");
            char input[1024];ssize_t n=read(STDIN_FILENO,input,sizeof input);
            if(n==0)fail("stdin closed without stop");
            if(n>0)pending.append(input,size_t(n));else if(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)fail("stdin read");
            if(pending.size()>4096)fail("command buffer bound");
            size_t newline;
            while((newline=pending.find('\n'))!=std::string::npos) {
                auto line=pending.substr(0,newline);pending.erase(0,newline+1);if(++commands>2048)fail("command count bound");
                std::istringstream words(line);std::string kind,a,b,c,extra;words>>kind;
                if(kind=="stop" && !(words>>extra)){stop=true;break;}
                if(kind=="ping" && (words>>a) && !(words>>extra)) {
                    std::cout << "{\"kind\":\"pong\",\"id\":" << number(a) << ",\"at\":" << now() << "}\n";continue;
                }
                if(sender && kind=="set" && (words>>a>>b>>c) && !(words>>extra)) {
                    auto next=number(a),newBase=number(b),newProbe=number(c);
                    if(next<=stage||next>64||newBase>12000000||newProbe>12000000||uint64_t(newBase)+newProbe>12000000)fail("stage/rate bounds");
                    if(budgetExhausted&&newProbe)fail("exhausted probe budget");
                    stage=next;base=newBase;probe=newProbe;tokens[0]=tokens[1]=0;leaseExpired=false;leaseDeadline=now()+.3;
                    std::cout << "{\"kind\":\"applied\",\"stage\":" << stage << ",\"baseBps\":" << base << ",\"probeBps\":" << probe << ",\"at\":" << now() << "}\n";continue;
                }
                if(sender && kind=="lease" && (words>>a) && !(words>>extra)) {
                    if(number(a)!=stage)fail("lease stage mismatch");
                    if(probe && !leaseExpired && now()<=leaseDeadline)leaseDeadline=now()+.3;
                    else if(probe){probe=0;leaseExpired=true;tokens[1]=0;}
                    continue;
                }
                fail("invalid command");
            }
            if(stop)break;
            const double elapsed=at-previous;previous=at;
            if(sender) {
                if(probe && at>leaseDeadline){probe=0;leaseExpired=true;tokens[1]=0;}
                for(unsigned kind=0;kind<2;kind++) {
                    const uint32_t rate=kind?probe:base;tokens[kind]=std::min(2720.0,tokens[kind]+elapsed*rate/8.0);
                    if(!rate||tokens[kind]<1360)continue;
                    if(kind && probeBytes+1316>16*1024*1024){probe=0;budgetExhausted=true;tokens[1]=0;continue;}
                    char data[1316]{};put(data,0x53475042);put(data+4,run);put(data+8,stage);put(data+12,kind);put(data+16,sequence[kind]);
                    int sent=srt_sendmsg(socket.id,data,sizeof data,-1,true);
                    if(sent==SRT_ERROR) {if(srt_getlasterror(nullptr)!=SRT_EASYNCSND)fail("send failed");continue;}
                    if(sent!=sizeof data)fail("partial message");tokens[kind]-=1360;sequence[kind]++;if(kind)probeBytes+=sizeof data;
                }
            } else {
                for(unsigned work=0;work<256;work++) {
                    char data[1500];int received=srt_recvmsg(socket.id,data,sizeof data);
                    if(received==SRT_ERROR){if(srt_getlasterror(nullptr)!=SRT_EASYNCRCV)fail("receive failed");break;}
                    if(received!=1316||get(data)!=0x53475042||get(data+4)!=run)fail("message identity/length");
                    auto nextStage=get(data+8),kind=get(data+12),seq=get(data+16);
                    if(kind>1||nextStage<stage||nextStage>64||!nextStage)fail("message stage/class");
                    if(nextStage!=stage){stage=nextStage;counts[0]=counts[1]=missing=duplicates=0;}
                    if(seen[kind] && seq<=lastSequence[kind]){duplicates++;totalDuplicates++;}
                    else {const uint64_t gap=seen[kind]?uint64_t(seq)-lastSequence[kind]-1:seq;
                        missing+=gap;totalMissing+=gap;counts[kind]++;totals[kind]++;lastSequence[kind]=seq;seen[kind]=true;}
                }
            }
            if(at-reportAt>=.05) {
                reportAt=at;
                if(sender) {
                    SRT_TRACEBSTATS stats{};check(srt_bstats(socket.id,&stats,0),"statistics");
                    std::cout << "{\"kind\":\"sample\",\"at\":" << at << ",\"stage\":" << stage << ",\"rttMs\":" << stats.msRTT
                      << ",\"bufferMs\":" << stats.msSndBuf << ",\"sentBytes\":" << stats.byteSentTotal << ",\"retransmittedBytes\":" << stats.byteRetransTotal
                      << ",\"droppedPackets\":" << stats.pktSndDropTotal << ",\"probePayloadBytes\":" << probeBytes
                      << ",\"probeLeaseExpired\":" << (leaseExpired?"true":"false") << ",\"probeBudgetExhausted\":" << (budgetExhausted?"true":"false")
                      << ",\"basePackets\":" << sequence[0] << ",\"probePackets\":" << sequence[1] << "}\n";
                } else std::cout << "{\"kind\":\"sample\",\"at\":" << at << ",\"stage\":" << stage << ",\"basePackets\":" << counts[0]
                  << ",\"totalBasePackets\":" << totals[0] << ",\"totalProbePackets\":" << totals[1] << ",\"totalMissing\":" << totalMissing << ",\"totalDuplicates\":" << totalDuplicates
                  << ",\"probePackets\":" << counts[1] << ",\"missing\":" << missing << ",\"duplicates\":" << duplicates << "}\n";
            }
            std::this_thread::sleep_for(std::chrono::microseconds(500));
        }
        socket.close();listener.close();
        std::cout << "{\"kind\":\"finished\",\"requestedStop\":" << (stop?"true":"false") << ",\"at\":" << now() << "}\n";
        return stop?0:2;
    } catch(const std::exception& error) { std::cerr << error.what() << '\n';return 1; }
}
