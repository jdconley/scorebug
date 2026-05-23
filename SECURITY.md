# Security Policy

Report vulnerabilities privately to **security@scorebug.live**. Please include reproduction steps and the affected component.

We aim to acknowledge reports within 72 hours.

Scorebug is a personal-scale system. The threat model assumes:
- Per-game SRT passphrases are split into publish vs read secrets.
- Bearer tokens (phone / home / internal) are rotatable env vars.
- The home machine accepts no inbound connections.

A multi-tenant deployment is **not** supported in v1 and would need OAuth or similar.
