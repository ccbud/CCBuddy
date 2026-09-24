# CCbuddy macOS release workflow

## Product rule and owner

The root `package.json` owns the app version. Every push to `main` publishes a
release, so installed apps keep receiving updates without a manual tag step. The
`verify` job owns version allocation and runs serialized in the
`ccbuddy-macos-release` concurrency group:

- If the root package version is newer than every `vX.Y.Z` tag, the main commit
  itself gets that annotated tag.
- Otherwise the job creates a release snapshot commit whose single parent is the
  main commit. It changes only the `version` field of the root, CLI workspace, and
  CLI package files to the highest tag's patch + 1, and its message carries
  `Release-Source-SHA: <main sha>`. `main` never moves; the tag keeps the snapshot
  reachable.
- A rerun for the same main commit reuses the tag already allocated to it, and an
  already public release skips the build.

An annotated `vX.Y.Z` tag pushed by a maintainer still starts a release, provided
it points at a commit on `main` or at a valid release snapshot. Tags pushed by the
workflow's `GITHUB_TOKEN` do not start a second run. GitHub Release owns the published
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
main push → allocate annotated tag (main commit or version snapshot)
annotated tag → version/ancestry check → signed arm64 build
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
2. A push to `main` allocates exactly one annotated version tag for that commit
   and publishes it. A lightweight tag, a tag outside merged `main` that is not a
   version-only snapshot of a `main` commit, or a tag whose version differs from
   the root and CLI packages cannot publish.
3. A valid tagged build embeds the CCbuddy latest manifest URL and emits signed,
   notarized artifacts whose ZIP hash matches the published YAML. The manifest
   contains no DMG or foreign update source.
4. Failed publication leaves only a draft. An existing public release and a
   newer latest version are never overwritten by a rerun or older tag.
