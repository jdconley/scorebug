# Local network impairment qualification

`pnpm test:native-network` runs the actual Mac native sender, simultaneous clean
archive, and SRT receiver through an owned loopback UDP proxy. Use the selected
Xcode toolchain explicitly:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:native-network
```

This fixture supplies repeatable bandwidth ceilings, propagation delay, and packet
loss without changing machine-wide networking. It does not model physical radios,
thermal pressure, or another host's encoder. Automatic stream quality remains off;
the existing probe explicitly changes live encoding from 6 to 2 Mbps after five
seconds. Local recording keeps its independent settings.

| Scenario    | Forward path                                    | Reverse path                   | Required outcome                                                                    |
| ----------- | ----------------------------------------------- | ------------------------------ | ----------------------------------------------------------------------------------- |
| Transparent | No rate cap, delay, or injected loss            | Same                           | All archive and normal live gates                                                   |
| Recoverable | 12 Mbps, 10 ms delay, drop every 100th datagram | 1 Mbps, 10 ms, drop every 80th | All archive and normal live gates; actual injected loss in both directions          |
| Overload    | 3 Mbps, 10 ms, 32 KiB queue                     | 1 Mbps, 10 ms                  | Complete archive, actual bounded queue overflow; report live degradation separately |

Rates charge actual datagram length plus 28 bytes of IPv4/UDP headers. SRT headers
are already inside the datagram. Each direction has a 16 KiB maximum token burst,
a 256-datagram queue, and a 256 KiB queue byte limit except the overload forward
queue. Configuration accepts finite rates from 1 bit/s through 1 Tbit/s; it rejects
rates that could overflow Node's timer range. These are ceilings with a bounded
burst allowance, not guaranteed delivered throughput or usable video capacity.

Scheduling uses monotonic elapsed time and a bounded token bucket. Propagation
delay does not consume tokens. A delayed timer cannot accumulate an unlimited
catch-up burst. Queued data is copied into a fixed-capacity ring, with separate
packet and byte limits. At most 16 dispatched sends per direction can be pending.
One timer per direction bounds scheduled work. The receiver address is always
127.0.0.1, the frontend pins its first sender endpoint, and foreign peers are ignored.

Shutdown stops admission, cancels timers, accounts for queued discards, joins pending
send callbacks, then closes both sockets. Closing sockets before those callbacks
can discard a pending unconnected UDP send without a callback; a real socket
regression reproduces that ordering. Socket failures invalidate qualification.
Forwarded counters mean UDP send attempts, not confirmed remote receipt.

Each run saves exact configuration, directional received/forwarded/drop counts,
queue and pending-send peaks, departure times, archive and live results, memory
observations, native transport samples, and process logs under `artifacts/qa`.
Qualification checks packet/byte conservation, rate plus burst bounds, empty joined
shutdown, actual traffic in both directions, and the scenario's injected effects.

Transparent and recoverable streams retain all existing full-decode, source frame,
frame cadence, A/V coverage/synchronization, publishing clock, native statistics,
and measured bitrate-change gates. Every scenario retains all archive gates.
Overload may fail live qualification; its result explicitly says so and preserves
the strict failure. A best-effort decoder reports complete raw frame samples even
when damage makes source identities unreadable. Invalid identities produce null
identity-based cadence/loss measurements, never an invented zero-frame success.

Implementation and verification are tracked in
[the plan](superpowers/plans/2026-09-15-local-network-impairment.md). This qualification
is groundwork for pressure and capacity controls; estimated SRT bandwidth alone
must not be treated as sustainable video bitrate.

The final impaired run (`dual-output-9tQV92`) preserves all 420 archive frames in
each scenario and all 420 live frames in transparent/recoverable scenarios. Deliberate
overload produces 4,097 forward queue drops and fails strict live decoding; its
best-effort decoder emits 389 frames whose source identities are not trustworthy.
The 13 native samples from each scenario show why SRT estimates alone are unsafe
capacity inputs: the 3 Mbps overload path briefly reports an estimated 721.332 Mbps,
while sender buffering reaches 148 ms and retransmitted bytes exceed 3.29 MB. Native
sender packet drops remain zero despite damaged receiver output. Neither sender
throughput nor that drop counter establishes successful video delivery.

The full tooling suite passes 694 tests (33 focused queue/socket/diagnostic tests).
The original five native scenarios pass at `dual-output-2SuTzI`, with all archives
complete and both normal streams at 420 frames. An earlier repeat failed the existing
250 ms producer-lag gate at 261.613 ms (`dual-output-IrG5NS`); that failure is preserved.
The unchanged final repeat stayed below 9 ms. This does not establish the cause or
resolve intermittent machine scheduling delays. The final evidence manifest is
`artifacts/qa/local-network-impairment-final-verification.json`.
