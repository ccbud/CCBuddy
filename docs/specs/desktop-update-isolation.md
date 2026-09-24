# CCbuddy desktop update isolation

## Product rule

Rebuilt CCbuddy keeps the previous CCbuddy version sequence: 2.0.9 is followed
by 2.0.10, then 2.0.11 for the main-view history revision. The Electron package
has its own package identity and update format.
A packaged build
must open its main window even when the upstream foundation project's service
advertises a higher `minimalVersion` (for example 3.5.3 while CCbuddy is
2.0.11). The inherited `/api/v1/client/configs` startup gate is not a CCbuddy
release policy and must not decide whether the app may start. Other feature-
config readers are outside this update boundary. The gate must not display an
upstream upgrade prompt or quit the app.

Automatic updates must never read the upstream foundation project's release
manifest. A production release build embeds `CCBUDDY_UPDATE_MANIFEST_URL` as an
HTTPS URL for CCbuddy's Electron YAML manifest and publishes that manifest with
its matching signed ZIP. The provider resolves relative artifact paths beside
the manifest, as electron-builder emits them; absolute URLs also work. The
manifest is uploaded only after the matching archive is available. An unset value disables both
background polling and manual update commands; Preview stays disabled. The
update entry is hidden when disabled, while an enabled updater keeps it visible
during checking and downloading so progress remains visible. The
bundled URL is fixed for that package. Runtime arguments or environment
variables cannot redirect a packaged app's update source. No new CCbuddy forced
upgrade policy exists yet; introducing one requires a separate app-owned
endpoint and a new spec before enabling a startup gate.

The copied settings schema may still contain the upstream, unnamespaced
`pendingPostUpdateReleaseNotes`. When new CCbuddy updates are disabled, startup must
not hydrate that entry into an installable update, and neither `UpdateReady` nor
`PostUpdateReleaseNotes` may be sent to a new CCbuddy window. Disabling clears
only in-memory update state; it leaves that legacy field untouched. A stale
upstream version must not produce an update toast, update button, or release-
notes prompt in the new app. When a new CCbuddy feed is configured, the updater
reads and writes only the separate `ccbuddyPendingPostUpdateReleaseNotes`
setting. The unnamespaced field is never restored, cleared, or overwritten by
the new update flow. The namespaced setting is the source marker for restart
recovery; its absence means there is no new CCbuddy update to recover.

## Owner, state, and interfaces

The desktop main process owns update policy and the existing `autoUpdater`
state machine. The build config supplies the immutable optional new CCbuddy manifest
URL. Desktop menu and command handlers read the same policy; renderer update
state is only a projection. `forceUpdateGuard.ts` remains a legacy implementation
module but is not called by new CCbuddy startup.

```text
build-time new CCbuddy manifest URL → desktop main policy → initAutoUpdater
                                             ├─ no URL: disabled state
                                             └─ HTTPS URL: existing update state machine
app-ready → primary-window coordinator → main window
```

There is no remote startup-update request before the main window. Background
checks happen after app-ready only if the new CCbuddy feed is configured. Disabling
the updater is idempotent; a missing or invalid manifest does not fall back to
the upstream manifest. The configured feed and installed version must use new
CCbuddy's own release sequence. Local data paths and shared library types are
not authorization to use the upstream release policy.

## Acceptance scenarios

1. Packaged production CCbuddy 2.0.11 starts normally even if the upstream endpoint
   publishes `minimalVersion: 3.5.3`; its startup force-update guard is never called.
2. With no new CCbuddy feed, the updater is disabled and no update menu or command
   can initiate an upstream manifest request. With a feed, checking and download
   progress remain visible even though the menu action is temporarily disabled.
3. A production build with a valid new CCbuddy HTTPS manifest uses the existing
   updater and only that manifest URL. Preview remains disabled.
4. A malformed or non-HTTPS build-time URL fails the build instead of silently
   using the upstream manifest.
5. With updates disabled and an inherited pending upstream release (for example
   3.5.3 while CCbuddy is 2.0.11), startup leaves the legacy setting untouched,
   clears the in-memory ready state, and sends no update-ready or release-notes
   event to a newly opened or reloaded window.
6. With a new CCbuddy feed configured, an inherited upstream pending release alone
   produces no new-app update state. A newly downloaded CCbuddy release persists
   under its namespaced key and can be restored after restart without changing
   the unnamespaced pending release.
7. The 2.0.11 Electron build can check and download a later signed Electron
   release from the configured CCbuddy YAML feed and install it on restart.
   CCbuddy 2.0.9 used a different updater and package identity, so migration
   from that installed app requires a separate release bridge. A local ad hoc
   signature is suitable for launch checks, not a public auto-update release.
