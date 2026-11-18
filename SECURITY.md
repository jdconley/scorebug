# Security Policy

Report vulnerabilities privately through GitHub: on this repository's **Security**
tab, choose **Report a vulnerability**. Please include reproduction steps and the
affected component. Do not open a public issue for a vulnerability.

We aim to acknowledge reports within 72 hours.

## What the service assumes

- People sign in with Google. Any Google account with a verified email can sign
  in and create teams; team data is visible only to that team's members.
- YouTube access is granted per team through Google OAuth. Refresh tokens are
  encrypted at rest and never sent to the phone.
- Each live match gets its own Cloudflare Stream input, deleted when the match
  ends. Match credentials can still read an ended match but can no longer score it.
- A second-phone scorer joins as a team member, or with a short-lived join code
  that grants scoring for one match. Code redemption is rate-limited.
- Service secrets live in Cloudflare Worker secrets and GitHub Actions secrets,
  never in this repository. Pull requests never get them: deploys
  run on pushes to `main` or by hand, and TestFlight uploads only from `main`.
