# Patched MediaMTX relay

Scorebug's SRT relay is MediaMTX 1.21.0 (revision
`2c6727904fbf233615de74a6c54a9b94dbf6025d`) with two patches. The MIT notice is kept
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

- **`h264-recovery.patch`**: keeps an SRT reader attached through damaged H.264 timing.
  Stock MediaMTX closes a reader when packet loss leaves the H.264 DTS extractor
  unable to continue (for example `too many reordered frames`), which ends the
  worker's FFmpeg input and forces a destination reconnect. The patch drops video
  until the next IDR with valid parameter sets, then resumes on the original PTS;
  audio continues. Waiting is bounded (300 access units or ten seconds), after which
  the reader fails as before. Go tests included.
- **`drain.patch`**: bounded retirement. Setting `scorebugDrain: true` on a path
  rejects new publishers and readers and closes existing connections after at most
  eight seconds, so the worker still receives the tail of a stream (the last rally)
  when a broadcast stops or its generation changes. The control plane drains
  obsolete paths, then deletes them once the source ends. If draining is not
  supported, it deletes the path directly.

Stock MediaMTX config cannot do either. Earlier patches for relay telemetry (ingress
clock origin, reader source, in-band bandwidth-probe accounting and its 4K format)
were removed with the adaptive-bitrate qualification work.

## Test

```sh
go test -race ./internal/protocols/mpegts                    # inside the patched source tree
go test -race ./internal/core -run '^TestScorebugDrain$'
pnpm test:relay                                              # real SRT admission and media
```
