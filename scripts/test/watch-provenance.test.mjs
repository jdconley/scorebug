import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

test(
  'Watch provenance gates reject foreign, changed, pending and malformed identities without mutating state',
  { skip: process.platform !== 'darwin' },
  async () => {
    const source = await readFile(
      new URL('../../ios/Sources/WatchSupport/WatchSetupProvenance.swift', import.meta.url),
      'utf8',
    );
    const directory = await mkdtemp(join(tmpdir(), 'watch-provenance-'));
    try {
      const path = join(directory, 'main.swift');
      await writeFile(
        path,
        source +
          `
func check(_ value: Bool) { assert(value) }
func rejects(_ action: () throws -> Void) { do { try action(); fatalError("accepted invalid provenance") } catch {} }
let game="10000000-0000-4000-8000-000000000001", foreign="10000000-0000-4000-8000-000000000002"
let pair="40000000-0000-4000-8000-000000000001", otherPair="40000000-0000-4000-8000-000000000002"
for bad: String? in [nil, "", "  ", "$(SCOREBUG_EXPECTED_WATCH_MATCH_ID)", "not-a-uuid", game+" "] {
 rejects { _ = try WatchSetupProvenance.expectedMatch(bad) }
}
// The marker must not let the phone proceed while Keychain restoration is loading.
check(try snapshot(ready:false).readyForOfferWait() == false)
check(try snapshot(busy:true).readyForOfferWait() == false)
check(try snapshot().readyForOfferWait() == true)
let expected = try WatchSetupProvenance.expectedMatch(game)
let selected = try WatchSetupProvenance.Identity(gameID:game,pairingID:pair)
let other = try WatchSetupProvenance.Identity(gameID:foreign,pairingID:otherPair)
func snapshot(offer:WatchSetupProvenance.Identity? = nil, pending:WatchSetupProvenance.Identity? = nil, paired:WatchSetupProvenance.Identity? = nil, scoringPending:Bool = false, ready:Bool = true, busy:Bool = false) -> WatchSetupProvenance {
 .init(offered:offer,pending:pending,paired:paired,setupPending:pending != nil,scoringPending:scoringPending,ready:ready,busy:busy)
}
let none=snapshot(), old=snapshot(offer:other,paired:other), current=snapshot(offer:selected,paired:other)
check(try none.matchingOffer(expected:expected) == nil)
check(try old.matchingOffer(expected:expected) == nil)
check(try current.matchingOffer(expected:expected) == selected)
check(try snapshot(offer:selected,ready:false).matchingOffer(expected:expected) == nil)
check(try snapshot(offer:selected,busy:true).matchingOffer(expected:expected) == nil)
try current.requireOffer(selected)
rejects { try old.requireOffer(selected) }
let replacement = try WatchSetupProvenance.Identity(gameID:game,pairingID:otherPair)
rejects { try snapshot(offer:replacement).requireOffer(selected) }
for p in [snapshot(offer:selected,pending:other), snapshot(offer:selected,pending:selected),snapshot(offer:selected,paired:other,scoringPending:true)] {
 let before = p.encoded
 rejects { _ = try p.readyForOfferWait() }
 rejects { _ = try p.matchingOffer(expected:expected) }
 rejects { try p.requireOffer(selected) }
 rejects { try p.requirePaired(selected) }
 assert(p.encoded == before, "pending metadata must remain unchanged")
}
try snapshot(paired:selected).requirePaired(selected)
for p in [none,snapshot(paired:other),snapshot(paired:replacement),snapshot(paired:selected,busy:true),snapshot(paired:selected,scoringPending:true)] {
 rejects { try p.requirePaired(selected) }
}
let hiddenPending=WatchSetupProvenance(offered:selected,pending:nil,paired:nil,setupPending:true,scoringPending:false,ready:true,busy:false)
rejects { try hiddenPending.requireNoPending() }
rejects { _ = try hiddenPending.readyForOfferWait() }
let roundTrip=try WatchSetupProvenance(encoded:current.encoded)
assert(roundTrip == current)
for malformed in ["missing", "{}", String(repeating:"x",count:1025),"{\\"ready\\":true}"] {
 rejects { _ = try WatchSetupProvenance(encoded:malformed) }
}
let invalidIdentity=current.encoded.replacingOccurrences(of:game,with:"invalid game with spaces")
rejects { _ = try WatchSetupProvenance(encoded:invalidIdentity) }
print("Watch provenance guards passed")
`,
      );
      const result = execFileSync('/usr/bin/xcrun', ['swift', '-D', 'DEBUG', path], {
        encoding: 'utf8',
        timeout: 60000,
        env: { ...process.env, DEVELOPER_DIR: '/Applications/Xcode-26.2.0.app/Contents/Developer' },
      });
      assert.match(result, /Watch provenance guards passed/);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);
