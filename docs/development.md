# Development

The server is a Cloudflare Worker (`apps/control-plane/src/worker`) that serves the iPhone app at
`https://scorebug.live`. Each live match runs the broadcast worker (`apps/home-daemon`) in a
Cloudflare Container. This page covers running the Worker locally, the iPhone apps, and the tests.

## Install

- Node 22.13 or later and pnpm 9.15.0 (`corepack enable` picks up the pinned version).
- Docker, for local match containers and the container test.
- FFmpeg with SRT, H.264 and AAC. On macOS use Homebrew's `ffmpeg-full`; the test scripts look for
  it in `/opt/homebrew/opt/ffmpeg-full/bin` before `PATH`.
- For the iPhone and Watch apps: Xcode 26.2 and XcodeGen (`brew install xcodegen`).

```sh
pnpm install --frozen-lockfile
```

## Run the Worker locally

`wrangler dev` runs the Worker with local D1 and Durable Objects:

```sh
cp apps/control-plane/.dev.vars.example apps/control-plane/.dev.vars   # fill in GOOGLE_CLIENT_SECRET
pnpm --filter @scorebug/control-plane exec wrangler d1 migrations apply scorebug --local
pnpm --filter @scorebug/control-plane dev:worker
```

It listens on `http://localhost:8787`.

- **Sign-in.** Google sign-in needs the real `GOOGLE_CLIENT_SECRET`, and the Google OAuth client
  must allow `<PUBLIC_URL>/v1/auth/google/callback`.
- **Beta list.** Only accounts on the beta list can sign in. Add yourself at `/admin`, which signs
  in the emails in `ADMIN_EMAILS`.
- **Go live.** Local containers are off (`dev.enable_containers` is `false` in
  `apps/control-plane/wrangler.jsonc`), so Go live answers `container_unavailable`. To go live
  locally, set it to `true`, run Docker, and put a real `STREAM_API_TOKEN` (Stream:Edit on the
  Cloudflare account) in `.dev.vars`.

To work on the app's screens and scoring without Google, Stream or YouTube, use the stand-in Worker
in `ios/AppUITests/LocalWorker` ([ios/README.md](../ios/README.md#screenshot-tour-against-a-local-worker)).

Production secrets are set once with `wrangler secret put`: `GOOGLE_CLIENT_SECRET`,
`SERVER_SECRET`, `ADMIN_EMAILS` and `STREAM_API_TOKEN`. Every push to `main` that changes the
control plane, the home-daemon image, the protocol package or the lockfile applies the D1
migrations and deploys (`.github/workflows/deploy.yml`).

## iPhone and Watch apps

```sh
xcodegen generate --spec ios/Project.yml
open ios/Scorebug.xcodeproj
```

Run the **Scorebug** scheme on a simulator or a device. The app uses `https://scorebug.live`. A
Debug build can use a local Worker: tap **Server** on the sign-in screen (or Settings → Developer),
pick `localhost:8787` or `127.0.0.1:8787`, then **Use this server**. Build and test commands,
releases and the screenshot tour are in [ios/README.md](../ios/README.md).

## Tests

`.github/workflows/ci.yml` runs the TypeScript and container tests. `.github/workflows/native.yml`
runs the Apple tests.

| Command                                             | What it checks                                                       | Needs             |
| --------------------------------------------------- | -------------------------------------------------------------------- | ----------------- |
| `pnpm test`                                         | Unit tests for every package, plus the `scripts/test` Node tests     | FFmpeg            |
| `pnpm --filter @scorebug/control-plane test:worker` | The hosted Worker in workerd: sign-in, teams, matches, Go live, site | —                 |
| `pnpm test:worker-container <image>`                | The worker image encodes and overlays real media                     | Docker, image tag |
| `pnpm -r typecheck`                                 | TypeScript                                                           | —                 |
| `pnpm format:check`                                 | Prettier                                                             | —                 |

The Apple tests:

```sh
swift test --package-path ios/Packages/ScorebugCore --scratch-path ios/.build/core
swift test --package-path ios/Packages/ScorebugMedia --scratch-path ios/.build/media
swift test --package-path ios/Packages/ScorebugStreaming --scratch-path ios/.build/streaming
xcodebuild test -project ios/Scorebug.xcodeproj -scheme ScorebugModelTests \
  -destination 'platform=macOS' -derivedDataPath ios/DerivedData/Model \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```
