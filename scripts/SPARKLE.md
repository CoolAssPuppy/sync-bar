# Sparkle setup for SyncBar

SyncBar uses the [Sparkle 2](https://sparkle-project.org/) framework for
auto-updates, exactly like mail-notifier and linear-bar. This document records
the one-time setup `./scripts/release.sh` depends on.

## Keys — SyncBar shares the existing Strategic Nerds key

SyncBar ships the **same** Ed25519 public key as mail-notifier and linear-bar.
It is already in `Info.plist` under `SUPublicEDKey`:

```
pySvjKDODAzK9Eiao1Cxni5AW6+rlLGUFOWAnaoAlfw=
```

(meeting-notifier uses a different key; SyncBar intentionally rides on the
mail-notifier / linear-bar key.)

**Do not run `generate_keys` without `-f`.** Generating a fresh key would mint a
new public key and strand every copy that ships with the value above. Instead,
**import the existing shared private key** under SyncBar' own keychain account
so `sign_update --account com.strategicnerds.SyncBar` can find it.

The same private key is already backed up in Doppler (it is what mail-notifier
and linear-bar sign with). Restore it under the SyncBar account once:

```bash
# Pull the shared private key PEM (same bytes used by the sibling apps):
doppler secrets get SPARKLE_PRIVATE_KEY_LINEARBAR \
  --project agent-server --config prd --plain > /tmp/sparkle_private.pem

# Import it under the SyncBar account (run after at least one build so the
# Sparkle SPM artifact exists):
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.strategicnerds.SyncBar -f /tmp/sparkle_private.pem

rm -P /tmp/sparkle_private.pem
```

Verify the import resolves to the expected public key (run with no flags; for
an account that already has a key, `generate_keys` just prints its public key):

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.strategicnerds.SyncBar
# Should report public key:  pySvjKDODAzK9Eiao1Cxni5AW6+rlLGUFOWAnaoAlfw=
```

(If you would rather give SyncBar its **own** keypair, generate one with
`generate_keys --account com.strategicnerds.SyncBar`, paste the printed
public key into `Info.plist`'s `SUPublicEDKey`, and back the private key up to a
new Doppler secret. That isolates SyncBar' update trust from the other apps.)

**Losing the private key permanently strands every installed copy.** Sparkle has
no key rotation.

## `sign_update` tool

`build-dmg.sh` expects Sparkle's `sign_update` at `$HOME/bin/sparkle/sign_update`:

```bash
mkdir -p ~/bin/sparkle
cp build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update ~/bin/sparkle/sign_update
chmod +x ~/bin/sparkle/sign_update
```

Or set `SPARKLE_SIGN_UPDATE` to override the path when invoking the release script.

## Notarization

The release script assumes a `notarytool` keychain profile named `agent-server`
(shared with the sibling apps). Create it once:

```bash
xcrun notarytool store-credentials "agent-server" \
  --apple-id <your-apple-id> \
  --team-id 955GSY56UT \
  --password <app-specific-password>
```

App-specific passwords are created at https://appleid.apple.com.

## Feed URL

The app points at the Dub shortlink `https://coolasspuppy.com/syncbar-updates`,
which must redirect to the live R2 appcast
(`https://downloads.strategicnerds.com/apps/syncbar/appcast.xml`). The shortlink
lets us repoint the feed later without shipping a new build.

Configure it once at https://dub.co: create a link with slug `syncbar-updates`
pointing at the R2 appcast URL above.

## End-to-end release flow

```bash
./scripts/release.sh 0.2.0 "<li>What changed.</li><li>Another thing.</li>"
git add project.yml dist/appcast.xml
git commit -m "Release 0.2.0"
git push
```

The script bumps the version, archives, exports a Developer ID `.app`, notarizes
and staples both the `.app` and the `.dmg`, Sparkle-signs the DMG, uploads the DMG
(versioned + `SyncBar-latest.dmg`) and `appcast.xml` to R2, and verifies the
live URLs respond.

## What you still need to do before the first real release

1. Import the shared Sparkle private key under `com.strategicnerds.SyncBar`
   (see "Keys" above), or decide to mint a SyncBar-specific key.
2. Stage `sign_update` at `~/bin/sparkle/sign_update`.
3. Confirm the `agent-server` notarytool profile exists.
4. Create the `syncbar-updates` Dub shortlink.
5. Confirm Doppler `agent-server/prd` has `CLOUDFLARE_API_TOKEN`,
   `CLOUDFLARE_ACCOUNT_ID`, `R2_BUCKET_NAME`, `R2_PUBLIC_BASE_URL`.
6. (Optional) Add `dmg-assets/background.tiff` + `dmg-assets/VolumeIcon.icns`
   to brand the DMG window; without them an unbranded DMG is built.
