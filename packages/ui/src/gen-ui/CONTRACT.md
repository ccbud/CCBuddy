# Gen UI

Submission freezes a single modelContent-only snapshot for its captured workspace,
session and command, then sends it in `genUiContext`, never concatenated with text.
The Host owns live widget state; canonical input intent owns accepted snapshots.
Queue, guide, retry and edit preserve that snapshot without re-reading the widget.
Nonempty context requires both Host and CLI support; older peers reject rather
than silently discard state. Explicit empty snapshots remain valid protocol data.

Completed assistant references create bounded desktop sandbox pages. One page remains mounted while its inline/expanded anchor changes. UI hooks select the execution Host for file reads and base desktop Host for state and registration. Follow-ups use the existing session input binding; read-only, stale and hidden bindings cannot send. State changes alone never start an Agent turn. No tools are exposed.

The window page owner shares admission and eviction capacity with MCP pages. Message components lease anchors and confirmation callbacks, not the guest lifetime. Natural-flow inline surfaces have no chrome, use content height (240px initial, 10,000px ceiling), and keep their node when elevated into a preview popover. Copy-image uses the owner-validated platform sandbox API. Tweak uses the object-binding runtime and serialized register/update/dispose acknowledgements. The page owner accepts registrations and projects preview commands; the old positional constructor is removed. Transient adjustments belong to the page owner, not a remounting panel.

The conversation parent owns inline width. Normal and wide cards fill its content width without a separate maximum; the compensated paint gutter does not change that layout boundary.

Gen UI projects control colors through `ccbuddy/genUiStyles`, separate from SDK
standard style variables. The root theme remains the only source; the existing
HostContext observer delivers updates. Expanded preview anchors pass bottom corner
radii to the retained page plane, clearing them while a tweak panel is open without
remounting the guest. Third-party MCP App style projection is unchanged.

Reference projection accepts the Unicode JSON marker, `::visualize{path="..." title="..." mode="wide"}`, and `::visualize{"path":"...","title":"..."}`. The existing assistant directive parser locates boundaries; JSON decoding belongs only to Gen UI projection. All forms use the same strict reference schema, Markdown code exclusions, completion gate and original message offsets. Messages need no migration.
