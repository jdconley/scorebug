# Scorebug field test

The first real run, end to end. Do it in this order, because each part depends on the one before. Write down anything odd with the time it happened, so it can be matched to the server logs (`infra/install.sh status`, `docker compose logs`).

## 0. At home, the day before

- [ ] Server is on the latest main (`infra/install.sh` re-run on the server, and `infra/install.sh worker` on the home worker if split). This writes the new `SERVER_SECRET` (replacing `PHONE_TOKEN`); update the API and the worker together, and re-pair the phone from the QR if it was set up with the old token.
- [ ] `infra/install.sh status`: control plane, relay and worker all healthy.
- [ ] YouTube: create a **private or unlisted** stream, check the key matches the one saved in Scorebug, and turn on *Auto-start* (and *Auto-stop* off) so YouTube goes live by itself.
- [ ] Phone: install **Scorebug Live** from TestFlight (internal group "Conley Chaos"). Delete any old dev build first so no stale pairing is left over.
- [ ] Connect: `infra/install.sh phone` on the server, then scan the QR with the iPhone camera. Home should show `Server … connected · YouTube ready`.
- [ ] Watch: install the Watch app from the iPhone's Watch app.
- [ ] Second phone (family member's): install the app, but **don't** connect it to the server.
- [ ] Free space: at least about 10 GB for a 1080p match (Home → Recordings shows what's free).

## 1. Dry run at home, 10 minutes

- [ ] New match: type both team names. Check the short names prefill and that you can edit them. Pick colors, Best of 3, the **Bar** scorebug, Stream to YouTube. Leave 4K off.
- [ ] Go live. Within about 10 s the LIVE pill shows and `720p out · good`. The YouTube preview plays with the scorebug burned in.
- [ ] Tap each half and check the score changes on the phone **and** on YouTube (about 5–15 s behind).
- [ ] Undo removes the last point on both.
- [ ] Watch: open Scorebug on the Watch. The teams and score appear in the same left/right order as the phone. Tap to score, then long-press to undo.
- [ ] Invite scorer: on the second phone, scan the QR, which should open the app and land on the scorer screen. Score a few points from it. The filming phone shows "scoring on another device" and **Take over** works.
- [ ] Bring a set to 25–2x. The set-point sheet appears on whichever device is scoring. Tap **Keep playing** once, then **End set**. "Teams switching sides?" appears; choose Yes and check the halves swap.
- [ ] Try scorebug styles: end, start a new match with **Lower third**, then **Set card**, and check each on YouTube.
- [ ] End the match. Recordings lists it. Play works and Save to Photos works.

## 2. At the gym

**Network**
- [ ] Note what the uplink is: gym Wi-Fi, or cellular (and how many bars).
- [ ] Go live and watch the quality line for the first 5 minutes. It should settle at `720p` or `540p out`, with no repeated "Retry stream" banners.
- [ ] Network drop: turn on Airplane mode for about 20 s, then turn it off. Recording continues the whole time and the stream comes back by itself. Note how long YouTube shows the "stream interrupted" slate.

**A full match** (one person filming and scoring)
- [ ] Tripod, landscape, whole court in frame. Score by tapping halves for the whole match.
- [ ] After each set, answer the switch-sides prompt. The halves should still match who is on which side.
- [ ] At least once, score a set from the **Watch** only (phone on the tripod).
- [ ] At least once, hand scoring to the second phone through Invite scorer, then take it back.
- [ ] Note the phone temperature: is any thermal warning or downshift to 540p shown? At what minute?
- [ ] Note battery percentage at the start and at the end. Is it plugged in or not?

**After the match**
- [ ] End match. YouTube goes off air, and the VOD has the scorebug and correct final scores.
- [ ] Recordings: the file covers the whole match with no gap at the network drop. Save to Photos works.
- [ ] Optional: a second match with **Record in 4K** on, to check heat over a full match.

## 3. Report back

For anything that went wrong, note the time, the screen it happened on, what you expected, and a screenshot. Also note which of these needed explanation or felt slow:

- connecting the phone
- the New match sheet
- inviting a scorer
- the set-point prompt
- the Watch
