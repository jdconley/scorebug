# Security Policy

Report vulnerabilities privately through GitHub: on this repository's **Security**
tab, choose **Report a vulnerability**. Please include reproduction steps and the
affected component. Do not open a public issue for a vulnerability.

We aim to acknowledge reports within 72 hours.

## What the hosted service assumes

- People sign in with Google. Access is invite-only, by email, during the beta.
- YouTube access is granted per team through Google OAuth. Refresh tokens are
  encrypted at rest and never sent to the phone.
- Each live match gets its own Cloudflare Stream input and its own match
  credentials. Both are revoked when the match ends.
- A second-phone scorer joins as a team member, or with a short-lived join code
  that grants scoring for one match. Code redemption is rate-limited.
- Service secrets live in Cloudflare Worker secrets and GitHub Actions secrets,
  never in this repository. Workflows only use them on pushes to `main`.

## Self-hosted deployments

- Per-match SRT passphrases are split into publish and read secrets.
- Bearer tokens (phone, worker, internal) are rotatable environment variables.
- The worker makes outbound connections only.
