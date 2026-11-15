# Measured native video cost

The current encoder may ignore requested bitrate. Upgrade admission must therefore
use actual compressed-byte cost, plus separately measured audio/mux/transport
reserves and receiver capacity. The next slice measures video payload on the real
publishing path without another encoder or any extra network traffic.

A publishing-attempt-owned scalar meter joins encoder completion metadata with
pre-mux compressed output by exact rational source PTS. This binds byte counts to
native encoder session/configuration, dimensions and publishing generation. Either
callback may arrive first; at most 64 unmatched records are retained. Duplicate,
malformed, inconsistent, reordered or missing joins quarantine this owner. Only
scalars are retained, never media. Teardown closes the meter after native stop joins.

Windows cover `(sourceStart, sourceEnd]`, excluding the first anchor's bytes. Each
window spans at least two source seconds and at most 2.25 seconds. It reports actual
H.264 payload bytes, frame count, source and submission durations, maximum frame
size and maximum callback latency. The conservative measured payload rate uses the
shorter source/submission duration. Fewer than 24 frames per second in either clock,
a gap over 250 ms, or output latency over 1.5 seconds makes the interval unusable.
Every interval has one exact native session/configuration/dimensions/generation.
An orderly configuration change starts a new anchor; it cannot borrow old bytes.
Closed/invalid owners expose no fresh cost. Historical summaries remain bounded.

An optional external observer can read each actual interval; ordinary publishing
creates the meter whenever it has application observation scope. The DEBUG native
format fixture exports its bounded history at joined stop. Qualification compares
all exported cost arithmetic and frame boundaries with separately retained raw pre-mux
callback records, and checks normal archive/live/audio and
cadence gates. Metadata is diagnostic and grants no quality-increase permission.

Alternatives considered: configured bitrate is disproven by current measurements;
a shadow encoder would allow a fresh candidate estimate but introduces additional
CPU/GPU load and lifecycle work. Start with the production payload meter, then use
it in bounded candidate measurement and repeated/staged admission. Historical cost
from a different scene or profile is not a prediction of current candidate cost.
