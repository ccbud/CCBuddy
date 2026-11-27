import { expandCliCustomCommandPrompt } from "./custom-command-expand.js";
const customCommandNotFoundPattern = /not found/i;
export function listCustomCommandSuggestions(customCommands) {
    return (customCommands?.commands ?? []).map((command) => ({
        name: command.name,
        summary: `${command.description} (${command.scope}/${command.source})`,
        usage: `/${command.name}${command.argumentHint ? ` ${command.argumentHint}` : ""}`,
    }));
}
export function findCustomCommandHelpEntry(name, customCommands) {
    return customCommands?.commands.find((command) => command.name === name);
}
export function formatCustomCommandHelpEntry(command) {
    return [
        `/${command.name}${command.argumentHint ? ` ${command.argumentHint}` : ""}`,
        command.description,
        `Source: ${command.scope}/${command.source}`,
        `Path: ${command.path}`,
    ].join("\n");
}
export function formatAvailableCommandNames(builtInCommands, customCommands) {
    const names = [
        ...builtInCommands,
        ...(customCommands?.commands.map((command) => `/${command.name}`) ?? []),
    ];
    return names.join(", ");
}
export async function buildCustomCommandPrompt(name, args, deps) {
    if (!deps.loadCustomCommand)
        return undefined;
    try {
        const command = await deps.loadCustomCommand(name);
        return expandCliCustomCommandPrompt({ args, command }).prompt;
    }
    catch (error) {
        if (error instanceof Error && customCommandNotFoundPattern.test(error.message)) {
            return undefined;
        }
        throw error;
    }
}
export async function listCustomCommandsForHelp(deps) {
    if (!deps.listCustomCommands)
        return undefined;
    try {
        return await deps.listCustomCommands();
    }
    catch {
        return undefined;
    }
}
