# Legacy native update bridge

## Problem and product rule

CCbuddy 2.0.3–2.0.9 shipped as a native Swift macOS app, and Tauri 1.3.9 shipped
before that. Those installed apps cannot be changed; their updater reads only
`https://github.com/ccbud/ccbud/releases/latest/download/latest.json` (GitHub
redirects the old repository name to `ccbud/CCBuddy`). The Electron releases
since 2.0.12 publish only `latest-mac.yml`. So `latest.json` returned 404 and
2.0.5 could not update.

Every production Electron release therefore also publishes a **legacy bridge**:
the same Electron app, re-signed under the old native identity, plus the
`latest.json` contract the old updater understands. After the bridge is
installed, it updates through `latest-mac.yml` like any other Electron build and
becomes `app.ccbuddy.desktop` on its next update.

## Frozen legacy client contract (from the v2.0.5 sources)

The old clients cannot change, so the bridge must meet every check below.

| Check          | Required value                                                                                                                                                                               |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Manifest       | JSON `{version, pub_date, platforms}`; `version` is semver and newer than the installed version                                                                                              |
| Platform keys  | arm64: `darwin-aarch64-app`, then `darwin-aarch64`; Intel: `darwin-x86_64-app`, then `darwin-x86_64`                                                                                         |
| Artifact entry | `url` (HTTPS, GitHub hosts), `signature`, `sha256` (lowercase hex)                                                                                                                           |
| Signature      | Tauri minisign format: Base64 of the four-line `.sig` text, prehashed Ed25519 (`ED`, BLAKE2b-512) by key id `FB130F2908B61575`                                                               |
| Archive        | gzip tar with exactly one top-level `*.app`, no absolute paths or `..`, no symlink resolving outside the app, at most 512 MiB                                                                |
| Bundle         | `CFBundleIdentifier = dev.ccbud.gateway`, `CFBundleShortVersionString` equals manifest `version`                                                                                             |
| Code signature | satisfies `anchor apple generic and certificate leaf[subject.OU] = "2CGR266XD2" and identifier "dev.ccbud.gateway"` with strict nested validation, and carries a stapled notarization ticket |

The Electron app itself uses `app.ccbuddy.desktop`, which fails the bundle and
code-signature checks. The bridge therefore needs its own identity.

## Bridge identity and handover to Electron updates

- The bridge is a copy of the signed, production `CCbuddy.app` whose outer
  `CFBundleIdentifier` and signing identifier are `dev.ccbud.gateway`. The product
  name, `userData` path, update feed URL, helpers, and nested signatures stay
  unchanged, so a bridge install and a normal install share the same data
  directory.
- Squirrel.Mac accepts an update only if it satisfies the running app's
  **designated requirement**. The bridge's designated requirement is therefore
  team-only: `anchor apple generic and certificate leaf[subject.OU] = "2CGR266XD2"`.
  This lets the bridge accept the next normal `app.ccbuddy.desktop` ZIP. Normal
  builds keep electron-builder's default designated requirement.
- The Developer ID team must be `2CGR266XD2`; a release signed by any other team
  fails before publication, because no old client could install it.

## Architecture scope

Electron releases are arm64 only. `latest.json` lists only the two
`darwin-aarch64*` keys. On Intel, the native 2.x updater finds no key and shows
its manual-download state, which links to the release page. Tauri 1.3.9 on
Intel reports a failed check. An arm64-only app is never offered to an Intel
Mac. Adding an Intel or universal Electron build later adds the `darwin-x86_64*`
keys.

## Owners and order

The release workflow owns the bridge; the app has no runtime code for it.

```text
build job (macOS, release environment)
  electron-builder → CCbuddy.app (app.ccbuddy.desktop) → notarize ZIP/DMG
  ditto copy → set CFBundleIdentifier → re-sign outer bundle (team-only DR)
  → verify legacy requirement + nested/strict + symlinks + normal app satisfies bridge DR
  → notarize bridge → staple → re-verify stapled
  → tar (single .app root) → Tauri signer (.sig) → latest.json (signature re-verified with the embedded public key)
publish job
  verify latest-mac.yml and latest.json against the downloaded bytes
  → draft release → upload all → compare inventory → publish as latest
old native / Tauri client
  GET releases/latest/download/latest.json → download bridge tar.gz → verify → install → relaunch
bridge (Electron, dev.ccbud.gateway)
  GET releases/latest/download/latest-mac.yml → Squirrel update → app.ccbuddy.desktop
```

`latest.json` is uploaded only in the same draft as its archive and becomes
visible only when the complete release is published as latest, so an old client
never sees a manifest without its archive.

The workflow needs the `TAURI_SIGNING_PRIVATE_KEY` secret (and
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, empty for an unencrypted key) in the
`release` environment. The signer is `@tauri-apps/cli` 2.11.3, the version the
native releases used.

## Acceptance

1. `releases/latest/download/latest.json` resolves for every new release. Its
   `version` equals the release version, it has exactly the two arm64 keys, and
   both point at the same archive URL in that release with the archive's SHA-256.
2. The signature decodes to four minisign lines, uses key id
   `FB130F2908B61575`, and verifies against the archive bytes with the public key
   embedded in the old clients. A wrong key, tampered archive, or non-canonical
   Base64 fails the build.
3. The archive has one `.app` root. The app inside is `dev.ccbud.gateway`, has the
   release version, satisfies the legacy code requirement, and carries a stapled
   ticket.
4. The normal `app.ccbuddy.desktop` build satisfies the bridge's designated
   requirement, so the bridge's first Electron update succeeds.
5. The normal ZIP, DMG, and `latest-mac.yml` are unchanged. `latest-mac.yml`
   never references a bridge asset.
6. Manual acceptance on a real Mac: 2.0.5 (arm64) installs the bridge and
   relaunches it; a newer release then updates the bridge to `app.ccbuddy.desktop`.
