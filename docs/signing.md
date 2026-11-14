# Signing

Tinycast has two signing identities:

- **Local builds** sign with a **stable self-signed identity** called `Tinycast Self-Signed`.
  Keeping the _same_ identity on every build is what makes macOS remember the Accessibility
  permission across rebuilds — ad-hoc signing changes every build and macOS forgets the grant. Each
  contributor creates their own, once (§1).
- **Releases** sign with the team's **Developer ID** and are notarized. That identity exists only in
  the release workflow's secrets (§2), so a contributor never needs it.

This fork also supports an existing Apple Development identity for local builds; see
[the local setup](#local-builds-on-this-fork).

## 1. Create the `Tinycast Self-Signed` identity (once)

For this fork's local builds, check the [local signing setup](#local-builds-on-this-fork) first.
Keep an existing Apple Development identity when it already signs the installed app.

Run these in a terminal. They generate a self-signed code-signing certificate and import it into your
login keychain:

```sh
# Generate a self-signed code-signing cert (10-year, codeSigning use).
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /tmp/tc-key.pem -out /tmp/tc-cert.pem \
  -subj "/CN=Tinycast Self-Signed" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# Bundle it as a .p12 (the non-empty password keeps `security import` happy).
openssl pkcs12 -export -inkey /tmp/tc-key.pem -in /tmp/tc-cert.pem \
  -name "Tinycast Self-Signed" -out /tmp/tc.p12 -passout pass:tinycast

# Import into the login keychain so codesign can use it without prompting.
security import /tmp/tc.p12 -k ~/Library/Keychains/login.keychain-db \
  -P tinycast -A -T /usr/bin/codesign

rm -f /tmp/tc-key.pem /tmp/tc-cert.pem /tmp/tc.p12
```

Verify it's there:

```sh
security find-identity -p codesigning | grep "Tinycast Self-Signed"
```

Now local builds (Xcode, VS Code F5, `xcodebuild`) sign with it, and you grant Accessibility once.

## Local builds on this fork

Accessibility grants track the app's bundle ID and signing requirement. An ad-hoc build's requirement
contains its binary hash (`cdhash`), which changes on rebuild. System Settings may still show an
enabled entry for the previous binary while the running app reports that it is untrusted.

`Config/Signing.xcconfig` keeps the upstream self-signed default and optionally reads the git-ignored
`LocalSigning.xcconfig` at the repository root. Xcode and command-line builds both use it. This Mac
uses its existing Apple Development certificate, matching `/Applications/Tinycast.app`.

Before configuring another checkout, inspect the installed app and available identities:

```sh
codesign -d -r- /Applications/Tinycast.app
security find-identity -v -p codesigning
```

Copy `LocalSigning.xcconfig` from the original checkout into any new worktree on this Mac. For a new
machine, select the existing signing certificate's SHA-1 fingerprint and team ID, then write:

```xcconfig
CODE_SIGN_IDENTITY = <existing certificate SHA-1 fingerprint>
DEVELOPMENT_TEAM = <existing certificate team ID>
```

Do not regenerate a certificate or switch identities on every build. The upstream self-signed setup
is for a machine that has no existing identity to preserve. Never commit private keys or certificates.

Use these commands for apps you intend to run:

```sh
./Scripts/build-local.sh Debug
./Scripts/build-local.sh Release --install
```

Both build in `build/DerivedData`, require signing, and reject ad-hoc identities on the app and OCR
helper. Release builds also verify their runtime flags and resource entitlements. `--install` verifies
the new copy against the installed copy's signing requirement before quitting, replacing and launching
it under `/Applications`. It stops if the identity changed. Set `TINYCAST_BUILD_VERSION` when updating
to a new release; otherwise it preserves the installed version string.
Debug is `Tinycast Dev` / `com.abueammar.tinycast.dev`; Release is `Tinycast` / `com.abueammar.tinycast`.

Unsigned compile checks are allowed only in a separate directory such as `build/CompileOnlyDerivedData`.
Never run or install those outputs. VS Code's build task uses the signed local build script.

If a permission entry already refers to an older signing identity, quit the affected app, remove that
entry from System Settings → Privacy & Security → Accessibility, add the signed app again and enable
it, then relaunch. That is a one-time repair after an identity change, not a rebuild step. Do not reset
TCC or remove permission entries during routine builds. Keeping the signer stable cannot preserve a
grant if another installer replaces the app with a differently signed release.

## 2. The release secrets

Releases read six secrets from the repo's `release` environment (**Settings → Environments**). The
environment deploys from `main` only, so a workflow pushed to any other branch can never read them.

| Secret                              | Holds                                                                                           |
| ----------------------------------- | ----------------------------------------------------------------------------------------------- |
| `DEVELOPER_ID_P12_BASE64`           | the Developer ID Application certificate and its private key, base64 `.p12`                     |
| `DEVELOPER_ID_P12_PASSWORD`         | the password the `.p12` was exported with                                                       |
| `NOTARY_KEY_P8_BASE64`              | an App Store Connect API team key (`.p8`) with Developer access, base64                         |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | that key's ID and its issuer ID                                                                 |
| `UPDATE_SIGNING_KEY`                | the release key: an Ed25519 private key, base64, whose public half is `TinycastUpdatePublicKey` |

Export the Developer ID identity alone — `security export -t identities` bundles every identity in
the keychain. In Keychain Access, open **My Certificates**, select
`Developer ID Application: … (J656U8XZ93)`, choose **File → Export Items…** and save a `.p12` with a
password. Then:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --env release --repo abue-ammar/tinycast
gh secret set DEVELOPER_ID_P12_PASSWORD --env release --repo abue-ammar/tinycast
base64 -i AuthKey_<key-id>.p8 | gh secret set NOTARY_KEY_P8_BASE64 --env release --repo abue-ammar/tinycast
gh secret set NOTARY_KEY_ID --env release --repo abue-ammar/tinycast --body "<key-id>"
gh secret set NOTARY_ISSUER_ID --env release --repo abue-ammar/tinycast --body "<issuer-id>"
gh secret set UPDATE_SIGNING_KEY --env release --repo abue-ammar/tinycast
```

The password and the private key go in at `gh`'s prompt, never through `--body`, which would leave
them in your shell history.

The release key is made once and never renewed. This prints its private half, then the public half
that goes into `Info.plist` as `TinycastUpdatePublicKey`:

```sh
echo 'import CryptoKit; let k = Curve25519.Signing.PrivateKey()
print(k.rawRepresentation.base64EncodedString(), k.publicKey.rawRepresentation.base64EncodedString())' |
    xcrun swift -
```

**Renew the certificate yearly.** Apple issues a Developer ID certificate for about 13 months.
Before it expires, the account holder creates a new one on developer.apple.com (**Developer ID
Application**, **G2 Sub-CA**) and replaces the two `DEVELOPER_ID_P12_*` secrets. Nothing else
changes: a shipped build stays valid because its signature carries Apple's timestamp, and macOS and
the updater both match the team rather than the certificate. The API key does not expire.

## Hardened runtime

**Release only**, on both targets: `ENABLE_HARDENED_RUNTIME: YES`, which notarization requires. Debug
must stay without it — hardened runtime turns on library validation, and Xcode's
`Tinycast Dev.debug.dylib` is refused at launch because a self-signed identity carries no Team ID for
the loader to match. The flag is not part of the designated requirement, so turning it on costs no
Accessibility grant. Each entitlement in `Tinycast/Tinycast.entitlements` earns its place:

| Entitlement | Without it |
| --- | --- |
| `com.apple.security.cs.allow-jit` | JavaScriptCore cannot JIT, and every extension command runs on the interpreter |
| `com.apple.security.automation.apple-events` | Every Apple event is refused with `-1743` and no prompt — Get Info, the Finder selection an extension reads, and the System Events–driven system actions all die silently |
| `com.apple.security.device.camera` | The camera prompt never appears and access resolves as denied |
| `com.apple.security.personal-information.calendars` | `requestFullAccessToEvents()` returns `false` in milliseconds with no dialog, and Tinycast never appears under System Settings › Calendars |

**A usage string is not enough under the hardened runtime.** `tccd` checks the matching entitlement
*before* it prompts, and without it logs "requires entitlement … but it is missing" and denies on the
spot — no dialog, no error, status still `.notDetermined`. A grant saved before the hardened runtime
arrived keeps working, since `tccd` does not re-check it, which is why this surfaces only on fresh
installs. Adding a protected resource therefore means adding its usage string *and* its entitlement.

`RESOURCE_ENTITLEMENTS` in `Scripts/verify-signature.sh` maps every protected resource's usage string
to its entitlement, including resources Tinycast does not use. That grants nothing — only
`Tinycast.entitlements` does, and a row whose usage string `Info.plist` doesn't declare is skipped. It
is there so a future feature that adds the usage string but forgets the entitlement fails the release
instead of shipping a prompt that can never appear.

Nothing else is needed: the only `dlopen` is Apple's own IOBluetooth, so library validation is left
on, and `node`, `ray` and shell commands are separate processes it never reaches. Bluetooth has no
hardened-runtime entitlement.

`./Scripts/verify-signature.sh <path-to-.app>` asserts all of this — the runtime flag and a
timestamped Developer ID signature on the app *and* every helper, an intact nested seal, no
`get-task-allow`, and an entitlement for every usage string `Info.plist` declares. Both release jobs
run it before submitting: a nested binary missing the runtime flag is the most common notarization
rejection, and a usage string missing its entitlement ships a permission that can never be granted.

## Update trust

The updater trusts a downloaded bundle through either of two roots
([features/updates.md](features/updates.md)):

- **The release key.** `Scripts/sign-update.swift` signs every updater zip with
  `UPDATE_SIGNING_KEY`, and refuses unless the built app's `TinycastUpdatePublicKey` is its public
  half, so a release can never ship trusting a key the next one is not signed with. The bundle must
  still carry a Developer ID signature, from any team, so a leaked key alone cannot ship an ad-hoc
  build.
- **The running copy's designated requirement**, read at runtime rather than pinned. For a Developer
  ID build that is the team, so a certificate renewal still matches.

**Never change both in one release.** A new Apple team ships signed by the old key, a new key under
the old team, and the release after that may change the other. `Scripts/check-update-path.sh`
enforces it: before notarizing, it downloads the last release on the channel and fails the run
unless that release trusts the new build's key or the new build satisfies its designated
requirement.

## Developer ID stays in CI

**The Developer ID identity stays a CI-only fact.** It is named in the release workflow's
`SIGNING_IDENTITY` and nowhere else: `project.yml` keeps signing with `Tinycast Self-Signed`, so a
contributor builds with the one they created in §1 — same name, their own key, never shared.

macOS keys a TCC grant to the app's designated requirement, so a certificate renewal keeps
Accessibility and every other grant, while a new team asks for each one again.

## Quarantine

A release is notarized and its DMG stapled, so Gatekeeper opens a downloaded copy without a warning.
A local `build-dmg.sh` DMG is self-signed and never notarized, so it is for testing on the Mac that
built it, not for sharing.
