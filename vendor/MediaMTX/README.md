# Patched MediaMTX relay

Scorebug's SRT relay is MediaMTX 1.21.0 (revision
`2c6727904fbf233615de74a6c54a9b94dbf6025d`) with three patches. The MIT notice is kept
in `LICENSE`. `upstream.json` pins the upstream archive and the hashes of the files
the patches touch. Go dependencies stay pinned by the upstream `go.mod` / `go.sum`.
The Docker build checks the archive SHA-256 and uses a pinned Go 1.26.1 builder.

## Build

From the repository root:

```sh
docker build -t scorebug/ingest:drain-v1 vendor/MediaMTX
# Add --platform linux/amd64 or linux/arm64 to target another architecture.
```

The image holds a static Linux binary and CA certificates. Mount a config at
`/mediamtx.yml`; a missing file is an error. `docker-compose.dev.yml`, `infra/vps`
and the CI relay test all use this image. The mock output sink in the dev stack is
stock MediaMTX.

## Patches

- **`scorebug.patch`**: relay metadata and recovery.
    - Publisher API items carry `scorebugTransportClock` (the first ingress MPEG-TS
      PTS) and reader items carry the source they are reading.
    - Bounded H.264 reader recovery: a timing error on an SRT read resynchronizes at
      the next clean keyframe instead of dropping the reader. Audio continues.
    - Accounting for in-band probe packets the phone can send to measure the link.
      Probe packets are counted and dropped; media passes through unchanged.
    - Go tests for each change.
- **`drain.patch`**: bounded retirement. Setting `scorebugDrain: true` on a path
  rejects new publishers and readers and closes existing connections after at most
  eight seconds. The control plane drains obsolete paths, then deletes them once the
  source ends. If draining is not supported, it deletes the path directly.
- **`uhd-probe.patch`**: accepts the version 4 probe format used for 4K streams.

## Test

```sh
go test -race ./internal/core -run '^TestScorebugDrain$'   # inside the patched source tree
pnpm test:relay                                              # real SRT admission and media
```
