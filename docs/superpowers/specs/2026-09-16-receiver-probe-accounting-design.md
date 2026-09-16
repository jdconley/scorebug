# Receiver probe accounting

The native publisher now reaches its requested optional load and withdraws under pressure while fixed-profile media survives. Upgrades still need receiver-delivered probe bytes, correlated to the authenticated publication and compared with measured candidate cost. Sender acceptance alone cannot provide that evidence.

## Design

Keep the existing 1,316-byte message, seven 188-byte MPEG-TS null packets and all sender lease/token/media-priority limits. Replace anonymous null payloads with a versioned marker repeated in each packet: eight ASCII bytes `SBUGPRB1`, 16 UUID bytes in network order, big-endian UInt64 publishing generation, big-endian UInt64 message sequence starting at zero, big-endian UInt32 requested accounted bit rate, and one packet ordinal (0–6). The remaining bytes stay `0xff`; the exact TS header is `47 1f ff 10`. Offsets are 4, 12, 28, 36, 44 and 48 respectively. This is not a secret or an authentication token.

H.222.0 permits arbitrary data bytes in null packets; demultiplexers discard them, and remultiplexing may remove them. Therefore observe after SRT delivery/decryption and before MPEG-TS demultiplexing. [ITU-T H.222.0, transport packet semantics](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.222.0-201703-S%21%21PDF-E&lang=e&type=items).

The sender builds the message inside its existing locked offer, using the current accepted-message count. Only successful native acceptance advances sequence; no send outside that lock or second socket writer is introduced. Failed/backpressured sends terminate the optional attempt under existing rules. The UUID distinguishes attempts, generation distinguishes native publication epochs, and bit rate identifies the offered load for this attempt. Multi-stage ramps must use explicit stage identities later; a rate change must never inherit this interval.

A bounded `io.Reader` wrapper on each relay publisher observes arbitrary read boundaries without changing a byte or error delivered to the demuxer. It retains at most one 188-byte partial packet and scalar accounting for one probe attempt. It counts a message only after all seven matching packet ordinals arrive in order. Wrong sequence/identity/generation/rate, malformed marker, clock reversal, or the 16 MiB byte bound permanently invalidate that connection's probe proof. Ordinary null packets and media are ignored. Invalid evidence never kills media. No ID map or unbounded history is permitted.

Expose an optional `scorebugBandwidthProbe` snapshot only on the authenticated publisher connection's existing private API item. It includes convention, probe ID, publishing generation, offered bit rate, complete delivered messages/payload bytes, next expected sequence, pending packet count, receiver elapsed nanoseconds (snapshot/first/last delivery), and an optional invalid reason. Integer counters and nanoseconds are decimal strings. Snapshot copies are independent. Publisher teardown clears the observer; readers, idle connections and replacement publishers must not inherit it. Absence means unavailable, never zero capacity.

The marker is publisher-supplied data. Authority comes from the relay's authenticated SRT connection and authenticated private API, then the existing control-plane binding of publisher UUID/query to the application's publishing attempt. Downstream qualification must match all of these scopes with the native probe UUID/generation/rate, retain request/response freshness bounds and reject stale or incomplete intervals. This primitive alone must not enable adaptive quality. Counts establish delivered optional payload, not transport overhead or preserved baseline media.

## Alternatives

Counting all null packets cannot attribute a probe. A separate probe connection tests a different flow. Inserting a private elementary stream would change program metadata and decoder behavior unnecessarily. Marked null packets keep media unchanged and provide exact pre-demux attribution.

## Acceptance and next integration

Cross-language vectors must agree on every byte. Swift tests must cover UUID/generation/rate/sequence encoding, sequencing only after acceptance, unchanged rate/lease/media-priority limits and actual socket bytes. Go tests must cover split/coalesced reads, bytes plus EOF, ordinary nulls, mixed media, malformed/duplicate/skipped/reordered/cross-scope packets, partial messages, budgets, monotonic timestamps, copied snapshots, concurrent reads/snapshots and publisher teardown. Existing relay clock/recovery tests and SDK tests must pass, with exact upstream patch round trips.

After this primitive passes, package a distinct relay image and collect authenticated snapshots in the native fixture. Compare actual accepted and delivered messages without bypassing archive/live/audio/cadence/cleanup gates. Then carry bounded fresh receiver intervals through the production control plane and combine them with measured candidate cost for upgrade admission. Physical devices, Watch networking and other worker hosts remain separate qualification requirements.
