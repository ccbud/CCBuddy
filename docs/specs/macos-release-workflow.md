# CCbuddy macOS release workflow

## Product rule and owner

The root `package.json` owns the app version. A reviewed, annotated `vX.Y.Z` tag
on the merged `main` history starts a release; merging a pull request alone does
not publish or change the update channel. GitHub Release owns the published
assets. The production Electron build embeds
`https://github.com/<repository>/releases/latest/download/latest-mac.yml` as its
immutable update source. Preview and unsigned PR packages have no update source.

The release contains one Developer ID signed macOS arm64 app as a ZIP for
automatic updates and a DMG for manual installation. The ZIP is notarized, the
DMG is notarized and stapled, and the published `latest-mac.yml` names only the
ZIP with its final SHA-512 and size. The ZIP blockmap matches that unchanged ZIP.
Both macOS jobs set `CCBUDDY_ENV=production` and
`CCBUDDY_PREVIEW_IDENTITY=0`: their app identity is `app.ccbuddy.desktop`,
their product name is `CCbuddy`, and their artifacts have no `_TEST` suffix.
The DMG is absent from the updater manifest because stapling changes its bytes
after electron-builder generates the initial manifest. Both archives are verified
before publication. A draft Release may hold partial upload state, but it becomes
public only after the complete asset inventory is verified. Existing public
releases are immutable; reruns cannot replace their assets or move `latest`
backwards to an older version.

## Flow and failure semantics

```text
PR → pnpm checks + unsigned arm64 package → review and merge
annotated tag on main → version/ancestry check → signed arm64 build
  → notarize ZIP and DMG → staple DMG → finalize YAML and verify assets
  → draft GitHub Release → upload and compare inventory → publish as latest
```

The GitHub `release` environment owns access to the Developer ID certificate and
Apple notary API key. Its required secrets are `MAC_CSC_LINK`,
`MAC_CSC_KEY_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`,
`APPLE_API_KEY_P8`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER`. Missing or invalid
credentials fail before publication. A temporary keychain and API key file live
only on the release runner and are removed afterward. The workflow never
generates a signing identity, publishes an ad hoc signed package, or uses the
removed native/Tauri release path.

If any signing, notarization, manifest, archive, or upload check fails, no public
release is created. A draft can be retried for the same tag. Publication uses the
repository's GitHub token with `contents: write`; PR jobs have read-only access
and no release credentials.

## Acceptance

1. A PR targeting `main` installs the locked pnpm workspace, runs typecheck,
   lint, formatting, architecture checks, targeted updater tests, and builds an
   unsigned arm64 ZIP and DMG without Apple credentials.
2. A plain push to `main`, a lightweight tag, a tag outside merged `main`, or a
   tag whose version differs from the root and CLI packages cannot publish.
3. A valid tagged build embeds the CCbuddy latest manifest URL and emits signed,
   notarized artifacts whose ZIP hash matches the published YAML. The manifest
   contains no DMG or foreign update source.
4. Failed publication leaves only a draft. An existing public release and a
   newer latest version are never overwritten by a rerun or older tag.
