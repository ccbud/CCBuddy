import { getCCbuddyCopy } from "@ccbuddy/i18n";
export async function listAppEffortOptions(app) {
    const levels = app.listThoughtLevels ? await app.listThoughtLevels() : undefined;
    return levels ? thoughtLevelsToEffortOptions(levels, app.getLocale?.()) : undefined;
}
export function thoughtLevelsToEffortOptions(levels, locale) {
    const effortCopy = getCCbuddyCopy(locale).tui.effort;
    return levels.map((level) => ({
        id: level,
        label: effortLabel(level, effortCopy),
    }));
}
function effortLabel(level, effortCopy) {
    if (level === "enabled")
        return effortCopy.enabled;
    if (level === "disabled")
        return effortCopy.disabled;
    return level;
}
