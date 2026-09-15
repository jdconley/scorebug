# Build context: vendor/MediaMTX. The archive, toolchain and Go dependencies are pinned.
FROM --platform=$BUILDPLATFORM golang:1.26.1-alpine@sha256:2389ebfa5b7f43eeafbd6be0c3700cc46690ef842ad962f6c5bd6be49ed82039 AS build
WORKDIR /src
RUN apk add --no-cache patch=2.8-r0
ADD --checksum=sha256:be643437fed01827ee05c40591326549db82a19eae5c41e12c0252971ed85ac6 https://codeload.github.com/bluenviron/mediamtx/tar.gz/2c6727904fbf233615de74a6c54a9b94dbf6025d /tmp/upstream.tar.gz
COPY scorebug.patch /tmp/scorebug.patch
RUN tar -xzf /tmp/upstream.tar.gz --strip-components=1 && patch -p1 < /tmp/scorebug.patch
RUN --mount=type=cache,target=/go/pkg/mod go mod download
# Upstream downloaders verify the pinned HLS/RPi asset SHA-256 values.
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build go generate ./internal/servers/hls ./internal/staticsources/rpicamera
RUN printf '%s' 'v1.21.0-scorebug-clock-v2' > internal/core/VERSION
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOARM=${TARGETVARIANT#v} go build -trimpath -ldflags='-s -w' -o /out/mediamtx .

FROM scratch
COPY --from=build /out/mediamtx /mediamtx
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY LICENSE /LICENSE
ENTRYPOINT ["/mediamtx"]
# Require an explicit mounted configuration rather than silently using defaults.
CMD ["/mediamtx.yml"]
