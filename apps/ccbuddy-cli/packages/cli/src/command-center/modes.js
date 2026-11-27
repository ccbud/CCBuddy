const SWITCHABLE_COMMAND_CENTER_MODES = [
    "plan",
    "build",
    "edit",
    "guarded",
    "yolo",
];
export function formatAvailableCommandCenterModes() {
    // 菜单不再推荐 Edit；显式旧命令仍由完整值域校验，不触发模式迁移。
    return SWITCHABLE_COMMAND_CENTER_MODES.filter((mode) => mode !== "edit").join(", ");
}
export function isSwitchableCommandCenterMode(value) {
    return SWITCHABLE_COMMAND_CENTER_MODES.includes(value);
}
