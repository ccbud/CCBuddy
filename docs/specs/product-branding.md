# CCbuddy product identity

The copied upstream runtime is an implementation foundation. The installed app,
CLI command, browser pages, user-visible copy, links, operating-system
integrations, repository-owned package names, paths, class and variable names,
CSS/DOM identifiers, protocol names, environment variables, comments, and
project documentation identify only as CCbuddy. No compatibility alias for the
upstream product name is shipped. The old CCbuddy sprout-and-CC logo is the
source for visible marks in light and dark themes, including the workspace
header and collapsed sidebar.
The loading and onboarding logo badge displays that same artwork at its full
96px tile size. It must not add a larger blue surround or replace the app icon
with a newly drawn mark.
The sidebar footer shows the full sprout-and-CC artwork within its rounded tile;
the parent control must not clip the top leaf or either C. The About dialog uses
the same original artwork as an image that fills its icon tile, never a traced
letterform, handwritten SVG, or inherited product glyph. Its heading identifies
the app simply as CCbuddy. A packaged build reads its bundled artwork rather
than assuming a repository working directory. The forced-update prompt also
uses the original CCbuddy artwork in development and installed builds; when the
image cannot be read, it shows a neutral CCbuddy text fallback, never a former
product initial. The icon has no independent mutable state: each window reads
the bundled asset and presents it without a competing brand cache. The compact
asset is `build/icons/128x128.png` in development and
`process.resourcesPath/ccbuddy-about-icon.png` in an installed desktop app.

Visible identity includes the window title, startup screen, onboarding, empty
workspace, About dialog, folder-opening context menus, external-link prompt,
Computer Use indicator, sidebar and CLI TUI. Web bootstrap errors and tabs
present CCbuddy. The inherited cloud conversation-share and import routes are
disabled; direct share URLs show an unavailable message without account
authentication. Help, issue-report, community, and changelog links resolve to
new CCbuddy repository resources without fetching the inherited cloud help config.
No user-facing action links to the upstream product website.

Model access is through services configured by the user. CCbuddy does not
present the inherited upstream account sign-in, Coding Plan, purchase, quota
upsell, or upstream endpoint controls on desktop, Web, or CLI. Login and purchase
deep links from the copied runtime are not product navigation routes. CCbuddy
uses `ccbuddy://` for its own remaining workspace links.

Bundled suggested-prompt icons are local assets. Remote runtime downloads have
no default upstream CDN: an operator must provide an explicit CCbuddy asset source
before a remote workspace can download runtime components.

Service errors that can reach a user, channel ownership notices, diagnostic
archive filenames, error-screenshot filenames and archive descriptions identify
as CCbuddy. Protocol types, method names, environment override keys and wire
values use the CCbuddy name on both sides of each boundary. An error-string
match in the runtime changes together with the error producer so recovery
behavior is preserved.

This rule also covers localized bot replies, session and compaction fallback
messages, legacy update prompts, and desktop host or storage errors that might
be shown in diagnostics. Git checkpoint commits authored by the app identify
CCbuddy in both author and committer name and email. Checkpoint ref names and
protocol keys use CCbuddy identifiers. UI error normalization continues to
prefer useful underlying provider messages over generic fallback copy.

CCbuddy does not auto-install a macOS Finder Services workflow. Windows Explorer
registry keys, Linux desktop entry and icon, and `ccbuddy://` URL scheme use
CCbuddy names. Registration and uninstallation must never overwrite or remove
entries owned by the former upstream product. Development bundles use CCbuddy
identities too.
The macOS window-bounds helper is built, bundled, and launched as
`ccbuddy-window-bounds`; no upstream-named helper process or resource is shipped.
The optional Windows browser import helper, service, named pipes, and assembly
identity also use CCbuddy names if that helper is built.
If the onboarding AGENTS.md migration is shown, its fallback target names
`~/.ccbuddy/AGENTS.md`, matching the path returned by the settings service.

## Release and CLI identity

The repository root `package.json` owns the CCbuddy version. The rebuilt app
continues the previous 2.0.9 version sequence: local revisions 2.0.10, 2.0.11,
and 2.0.12 increment the patch number. The CLI workspace and executable package use
the same version; the executable is
`ccbuddy` only.
The repository exposes `pnpm ccbuddy`. English and Chinese help, doctor
output, and command usage present `ccbuddy`.

Desktop package metadata links to the CCbuddy repository. The macOS release
doctor defaults to `/Applications/CCbuddy.app`. The release command may
create a local commit and tag, but it must not push automatically. Runtime
update policy is specified in `desktop-update-isolation.md`.
Production builds remove stale main, host, preload, scheduler, and renderer
outputs before packaging, so an earlier build cannot leak old identifiers into
the new app archive.

The SEA upload utility requires an explicit, pre-existing destination root;
it must not infer an upstream SMB destination. Upload directories use the
`ccbuddy-cli-` prefix. The Windows installer presents CCbuddy and emits
CCbuddy-named diagnostic files. Its manifest and data-directory guard use
CCbuddy-owned names. It may also protect another product's existing directory
from destructive cleanup, without claiming ownership of it.

Acceptance: `pnpm ccbuddy --version` matches the root version; help and
invalid-command usage show `ccbuddy`; no former executable alias is shipped;
macOS, Windows, and Linux register only CCbuddy product IDs and URL schemes;
running the SEA uploader without `--dest-root` fails before writing; release
configuration disables automatic remote push; and visual smoke checks show
the CCbuddy name and logo throughout desktop, Web, and TUI.
Visual acceptance includes the About dialog, sidebar footer at normal and
collapsed widths, and forced-update prompt in packaged and development modes.
The old sprout and both C letters remain fully visible at icon size, and no
single-letter substitute appears if an optional image fails to load.
Service error and diagnostic smoke checks contain no former product name, while
transport-close and request-timeout recovery still recognize their errors.
