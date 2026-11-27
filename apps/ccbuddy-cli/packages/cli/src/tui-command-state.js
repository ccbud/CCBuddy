export const TUI_TITLE_GENERATION_CONFIG = {};
export const createCliModeState = (mode) => ({
    current: mode,
    override: mode,
});
export const currentCliMode = (state) => state.current ?? state.override ?? "build";
/** The TUI's Plan entry projects the runtime's independent planning flag. */
export function readTuiMode(app, fallback) {
    return app.runtime?.getPlanEnabled?.() ? "plan" : (app.getMode?.() ?? fallback);
}
