# Scorebug field test

A real match with the hosted app, end to end. Go in order: each part depends on the one before.
Write down anything odd with the time it happened, so it can be matched to the Worker logs in the
Cloudflare dashboard.

You need the filming iPhone on a tripod, its paired Apple Watch, and a second phone for scoring.

## 1. At home, the day before

- [ ] Filming iPhone: install **Scorebug** from TestFlight. Install it on the Watch too, from the
      Watch app on the iPhone if it doesn't appear by itself.
- [ ] **Sign in with Google.** Home appears. If it says "Scorebug is in private beta", the account
      isn't on the beta list yet.
- [ ] Team: tap **Create team**, or open the invite link from your team owner. Tap the team on Home
      to open the team screen.
- [ ] YouTube (team owner): **Connect a YouTube channel** and finish Google's YouTube consent. The
      channel status reads "Matches go live here, unlisted". If it says the channel can't live stream
      yet, wait out YouTube's 24 hours and tap **Check again**.
- [ ] Second phone: install Scorebug. Either join the team (**Invite people** → **Create invite
      link** → **Share invite**, then open the link on that phone and tap **Join team**), or plan to
      join the match with a code at the gym.
- [ ] Free space: Home → **Recordings** shows how much is free. Leave about 10 GB for a 1080p match.

## 2. Dry run at home, 10 minutes

- [ ] **New match** on the team. Team 1 is your team. Type Team 2's name and check its short name
      fills in and can be edited. Pick colors, **Best of 3 · 25/15** and the **Bar** scorebug.
      **Stream to** shows the team's channel. Leave **Record in 4K** off.
- [ ] **Go live.** The screen turns landscape, the LIVE pill appears and the status line settles at
      something like `REC 1080p · 720p out · good`.
- [ ] **Watch link**: send it to another device and open it. The YouTube stream plays with the
      scorebug burned in.
- [ ] Tap each half of the picture. The score changes on the phone and, a few seconds later, on
      YouTube. **Undo** removes the last point on both.
- [ ] Watch: open Scorebug. The teams and score appear in the same left/right order as the phone.
      Tap to score, then long-press to undo.
- [ ] **Invite scorer** on the filming phone. On the second phone, point the camera at the QR code
      and tap **Join and score** (or **Join with a code** and type the code). Score a few points from
      it. The filming phone shows **Scoring on another phone · Take over**; tap it and check scoring
      comes back.
- [ ] Bring a set to set point. The prompt "… wins set 1?" appears on the phone that is scoring. Tap
      **Keep playing** once, then score again and tap **End set**. "Teams switching sides?" appears;
      tap **Yes, switch** and check the halves swap.
- [ ] **End** → **End match**. The match card shows the result and "Saving the video…", then
      **Done**. YouTube goes off air.
- [ ] Recordings lists the match. **Play** and **Save to Photos** work.
- [ ] Try the other scorebug styles: a short match with **Lower third**, then **Set card**, and check
      each on YouTube.

## 3. At the gym

**Network**

- [ ] Note the uplink: gym Wi-Fi, or cellular (and how many bars).
- [ ] **Go live** and watch the status line for the first 5 minutes. Note where it settles
      (`1080p`, `720p` or `540p out`) and any banners.
- [ ] Network drop: turn on Airplane mode for about 20 seconds, then turn it off. The recording
      keeps going the whole time. Note whether the stream comes back by itself ("Reconnecting
      stream…") or needs **Go live again**, and what YouTube shows meanwhile.

**A full match**, one person filming and scoring

- [ ] Tripod, landscape, whole court in frame. Score by tapping the halves for the whole match.
- [ ] After each set, answer "Teams switching sides?". The halves still match who is on which
      side.
- [ ] Score at least one set from the Watch only, with the phone on the tripod.
- [ ] At least once, hand scoring to the second phone through **Invite scorer**, then take it back
      with **Take over**.
- [ ] Note the phone's temperature: any drop in stream quality, and at what minute.
- [ ] Note the battery at the start and the end, and whether the phone was plugged in.

**After the match**

- [ ] **End** → **End match**. YouTube goes off air. The YouTube video has the scorebug and the
      right final score.
- [ ] Recordings: the file covers the whole match, with no gap at the network drop. **Save to
      Photos** works.
- [ ] Optional: a second match with **Record in 4K** on, to check heat over a full match.

## 4. Report back

For anything that went wrong, note the time, the screen, what you expected, and a screenshot. Also
note which of these needed explaining or felt slow:

- signing in and connecting YouTube
- the New match sheet
- inviting a scorer
- the set-point prompt
- the Watch
