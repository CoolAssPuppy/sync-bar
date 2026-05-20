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

**Do not run `generate_keys` without a key file.** Generating a fresh key would
mint a new public key and strand every copy that ships with the value above.

The private key lives in Doppler, not the keychain. `build-dmg.sh` reads
`SPARKLE_PRIVATE_KEY` from `sync-bar/prd`, writes it to a short-lived temp file,
and signs with `sign_update --ed-key-file`. No keychain import is required — any
machine with Doppler access to the `sync-bar` project can cut a release.

Confirm the key is present and resolves to the shipped public key:

```bash
doppler secrets get SPARKLE_PRIVATE_KEY --project sync-bar --config prd --plain \
  | python3 -c 'import sys, base64; from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey; \
seed = base64.b64decode(sys.stdin.read().strip()); \
print(base64.b64encode(Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes_raw()).decode())'
# Should print:  pySvjKDODAzK9Eiao1Cxni5AW6+rlLGUFOWAnaoAlfw=
```

`SPARKLE_PRIVATE_KEY` is the 44-char base64 Ed25519 private key (the same bytes
mail-notifier and linear-bar sign with). It is also mirrored in `sync-bar/dev`
and `sync-bar/stg`.

**Losing the private key permanently strands every installed copy.** Sparkle has
no key rotation. Keep the Doppler secret backed up.

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
which must redirect to the live R2 appcast at
`$R2_PUBLIC_BASE_URL/apps/syncbar/appcast.xml`
(currently `https://pub-9c8d72fe664b4ce18aac0d718b4e0346.r2.dev/apps/syncbar/appcast.xml`).
The shortlink lets us repoint the feed later without shipping a new build.

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

1. Stage `sign_update` at `~/bin/sparkle/sign_update`.
2. Confirm the `agent-server` notarytool profile exists.
3. Create the `syncbar-updates` Dub shortlink (see "Feed URL" above).
4. Confirm Doppler `sync-bar/prd` has `CLOUDFLARE_API_TOKEN`,
   `CLOUDFLARE_ACCOUNT_ID`, `R2_BUCKET_NAME`, `R2_PUBLIC_BASE_URL`, and
   `SPARKLE_PRIVATE_KEY`.
5. (Optional) Add `dmg-assets/background.tiff` + `dmg-assets/VolumeIcon.icns`
   to brand the DMG window; without them an unbranded DMG is built.
