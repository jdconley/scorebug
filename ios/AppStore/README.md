# App Store listing and media

Everything on Scorebug's App Store page (app 6835267544, "Scorebug Live"), and how to remake it.
Every claim in the copy is something the app does today.

| File | What it is |
| --- | --- |
| `listing.json` | Name, subtitle, categories, URLs, promotional text, description, keywords, copyright, territories |
| `review-notes.txt` | The notes for App Review (no demo account: any Google account signs in) |
| `listing.mjs` | Puts all of the above, the age rating, the price (free) and availability into App Store Connect |
| `upload-media.mjs` | Uploads `screenshots/` and `preview/` to App Store Connect, replacing what's there |
| `asc.mjs` | The App Store Connect API client the scripts use (Admin key, see `ios/README.md`) |
| `gym.jpg` | A generated photo of an empty gym: the camera's view in every screenshot. No real people |
| `capture.sh` | Raw screenshots from a simulator (`StoreMediaTests`), live against the local Worker |
| `capture-watch.sh` | Raw Apple Watch screenshots, from match states passed to the Watch app |
| `frame.swift`, `captions.json` | Captioned, framed store screenshots from the raw ones |
| `preview.sh` | The App Store preview video |
| `creative.sh` | The header and search result art (3840x1646, 3840x2560) |
| `screenshots/`, `preview/`, `creative/` | What was uploaded |

## Listing

```sh
node ios/AppStore/listing.mjs --dry-run   # what it would change
node ios/AppStore/listing.mjs
```

It updates the version in Prepare for Submission. The App Review contact isn't in this public
repo: the script copies it from the team's other app (`reviewContactFromApp`).

Availability is the US only (`territories`), so the App Store doesn't ask for a Digital Services
Act trader listing. Pricing is free.

### Age rating: 4+

Every content descriptor is None. No unrestricted web access (the app has no web view; watch
links open in YouTube or Safari), no user-generated content shown in the app (video goes to the
team's own YouTube channel; the app shows only team names and scores the team enters), no
messaging, ads, gambling, contests or loot boxes.

### Privacy label

Entered in App Store Connect (App Privacy), matching `ios/Resources/PrivacyInfo.xcprivacy`:

- **Data used to track you:** none.
- **Data linked to you, for App Functionality only:** Name and Email Address (from Google
  sign-in), User ID (the Google account ID), Other User Content (team names, match scores).
- **Not collected:** video. It goes from the phone through Cloudflare Stream and the match
  container to the team's YouTube channel in real time and isn't kept (Stream recording is off).
  Recordings stay on the phone. No analytics, diagnostics, location, contacts or identifiers for
  advertising.

## Screenshots

Sizes are Apple's required slots: iPhone 6.3" (1206x2622 / 2622x1206), iPad 13" (2064x2752 /
2752x2064) and Apple Watch Ultra 3 (422x514). JPEG, no alpha, under 1.5 MB.

```sh
ios/AppStore/capture.sh <iphone-17-pro-udid> /tmp/raw-iphone
ios/AppStore/capture.sh <ipad-pro-13-udid> /tmp/raw-ipad
ios/AppStore/capture-watch.sh <watch-ultra-3-udid> /tmp/raw-watch
swift ios/AppStore/frame.swift /tmp/raw-iphone ios/AppStore/screenshots iphone
swift ios/AppStore/frame.swift /tmp/raw-ipad ios/AppStore/screenshots ipad
n=1; for s in score setpoint swap; do cp /tmp/raw-watch/$s.png ios/AppStore/screenshots/watch-$n.png; n=$((n+1)); done
```

Watch screenshots go up as captured, with no frame or caption.

`capture.sh` needs `srt-live-transmit` (`brew install srt`), ffmpeg and ImageMagick 7. It turns
`gym.jpg` into the clip the Simulator camera reads, starts the local Worker with Go Live pointed at
an SRT listener on this Mac (so the live screen is really live), and runs `StoreMediaTests`.

## Preview video

```sh
ios/AppStore/preview.sh <iphone-17-pro-udid> ios/AppStore/preview
```

It records the Simulator while `StoreMediaTests/testPreview` plays the end of a live set, then
cuts 1920x886 H.264 with a quiet stereo room-tone track (previews need audio), 15 to 30 seconds.

## Uploading

```sh
node ios/AppStore/upload-media.mjs
```

The privacy label is answered in App Store Connect (App Privacy), and the header and search
result art (`creative/`, made by `creative.sh`) is uploaded on the version page under Header and
Search Results; the API sets neither.

## The website

`scripts/build-site-media.sh` makes scorebug.live's images and clips from the same raw captures
and preview, plus the scorebug styles drawn by the match container's own renderer
(`pnpm --filter @scorebug/home-daemon render-scorebug <dir> --media`), into `apps/control-plane/public/media`.
