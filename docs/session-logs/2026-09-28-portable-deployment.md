# September 28 — portable deployment

Starting checkout: `codex/local-validation`, commit15d50d9, clean. The previous goal turn made verified progress (native vertical plus measured congestion evidence); no live job was carried over. Hardware remains deferred.

Repaired the obsolete VPS template using the approved portable architecture: bridge networking with explicit SRT UDP mapping, current pinned/patched relay source, API-managed generation paths, private password-authenticated management, and persistent SQLite storage. Removed obsolete game-path callbacks and host-network localhost assumptions. Empty secrets block startup. Updated deployment and worker runbooks with configuration, stable installation identity, persistence, backup, upgrades/rollback and external qualification limits.

Added `node scripts/test-vps-stack.mjs [--image IMAGE]` and a CI step reusing existing built images. This uses only an owned temporary Compose project, random credentials and loopback ports. The first run (`vps-stack-c8ivpH`) established auth/provisioning and container recreation but its comparison incorrectly included changing serverTime; the corrected run (`vps-stack-wozlWz`) passes all five checks: private management ports, management authentication, native relay provisioning, persistent match/credential/grant after API recreation, and path removal on stop. Cleanup passes. No phone/Watch tests or media replays were repeated.

This is local Linux-container deployment evidence, not remote-host, public DNS/TLS, GPU or sustained media qualification. Existing congestion damage and remote Watch match-end overhang remain unresolved. The installed Mac service and native app recovery across process faults also remain open. No deployment, purchase, push or PR occurred.
