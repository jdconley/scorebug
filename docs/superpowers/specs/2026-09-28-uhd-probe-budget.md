# Bounded UHD admission

Goal: admit a real4K upload only when source geometry, configured worker output,
measured candidate cost and receiver delivery support it. Keep the normal startup
at240p and the existing minimum fallback. A4K archive alone is not upload evidence.

## Wire and native ownership

Use `SBUGPRB4` / `mpegts-null-probe-v4` for an explicitly selected UHD publication.
Its layout is v3's campaign/stage layout; it permits48Mbps target rate and64MiB
payload per campaign. v1–v3 keep their existing rate and16MiB limits. A publication
cannot switch versions, and every stage/campaign retains the same native budget.
Campaign counters are UInt32; all publication totals fit UInt64 and cross JSON as
canonical decimal strings. Partial packets reserve one complete1316byte message.

Why these bounds: a24Mbps video candidate plus128kbps AAC produces a36.192Mbps
nominal probe target under the existing1.5× scheduling estimate. A48Mbps ceiling
leaves room for measured mux/framing overhead, with a corresponding32Mbps measured
cost ceiling.64MiB bounds a whole campaign while accommodating the short holds,
source alignment and four-second candidate collection. Hitting the byte bound is a
failed attempt, never permission to extend it. The existing60second campaign and
300ms renewable lease bounds remain. UHD wakes are at least200microseconds apart;
each opportunity can bank/send only one1360byte wire token. Late callbacks cannot
burst accumulated traffic. Actual achieved receiver throughput still gates admission.

## Application integration still required

Carry the immutable budget through publisher reservation/readback wrappers and
candidate planning; keep legacy audits/version bounds intact. Select the UHD budget
and4K ladder only for a4K capture and a fresh worker configured for2160p output.
Require matching receiver v4 evidence. Older/missing capabilities retain the normal
1080p ceiling. Add a true4K native ordinary workflow, with minimum startup, measured
climb, independent archive, native score change and both overlaid output recordings.
Do not enable4K production upload before that path has actual throughput evidence.
