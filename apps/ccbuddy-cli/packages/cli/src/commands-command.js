import { formatJson } from "@ccbuddy/core";
const COMMANDS_COMMAND_USAGE = "Usage: ccbuddy commands [list|inspect <name>]";
export async function runCommandsCommand(ctx, options, deps, args) {
    const subcommand = args[0] ?? "list";
    if (subcommand === "list") {
        if (args.length > 1)
            return failUsage(ctx);
        return await runCommandsListCommand(ctx, options, deps);
    }
    if (subcommand === "inspect") {
        if (args.length !== 2 || args[1]?.trim().length === 0)
            return failUsage(ctx);
        return await runCommandsInspectCommand(ctx, options, deps, args[1]);
    }
    ctx.stderr.write(`Unknown commands command: ${subcommand}\n${COMMANDS_COMMAND_USAGE}\n`);
    return 1;
}
function failUsage(ctx) {
    ctx.stderr.write(`${COMMANDS_COMMAND_USAGE}\n`);
    return 1;
}
async function runCommandsListCommand(ctx, options, deps) {
    try {
        const workingDirectory = (deps.cwd ?? process.cwd)();
        const listCustomCommands = await resolveListCustomCommands(deps);
        const outcome = await listCustomCommands({
            env: deps.env ?? process.env,
            logger: deps.logger,
            workingDirectory,
        });
        ctx.stdout.write(options.json
            ? formatCommandJson(outcome, workingDirectory)
            : formatHumanCommandList(outcome, options));
        return 0;
    }
    catch (error) {
        return reportCommandsError(ctx, options, error);
    }
}
async function runCommandsInspectCommand(ctx, options, deps, name) {
    try {
        const workingDirectory = (deps.cwd ?? process.cwd)();
        const inspectCustomCommand = await resolveInspectCustomCommand(deps);
        const inspection = await inspectCustomCommand({
            env: deps.env ?? process.env,
            logger: deps.logger,
            name,
            workingDirectory,
        });
        ctx.stdout.write(options.json
            ? formatCommandInspectionJson(inspection, workingDirectory)
            : formatHumanCommandInspection(inspection, options));
        return 0;
    }
    catch (error) {
        return reportCommandsError(ctx, options, error);
    }
}
async function resolveListCustomCommands(deps) {
    if (deps.listCustomCommands)
        return deps.listCustomCommands;
    const bootstrap = deps.loadBootstrapModule ?? (() => import("@ccbuddy/bootstrap"));
    return (await bootstrap()).listCCbuddyCustomCommands;
}
async function resolveInspectCustomCommand(deps) {
    if (deps.inspectCustomCommand)
        return deps.inspectCustomCommand;
    const bootstrap = deps.loadBootstrapModule ?? (() => import("@ccbuddy/bootstrap"));
    return (await bootstrap()).inspectCCbuddyCustomCommand;
}
function reportCommandsError(ctx, options, error) {
    const message = error instanceof Error ? error.message : String(error);
    ctx.stderr.write(`Error: ${message}\n`);
    if (options.verbose && error instanceof Error && error.stack) {
        ctx.stderr.write(`${error.stack}\n`);
    }
    return 1;
}
function formatHumanCommandList(outcome, options) {
    if (outcome.commands.length === 0) {
        return "No custom commands found.\n";
    }
    const lines = [`Custom commands (${outcome.commands.length})`];
    for (const command of outcome.commands) {
        lines.push(`- /${command.name}${command.argumentHint ? ` ${command.argumentHint}` : ""}`);
        lines.push(`  ${formatCommandDescription(command)}`);
        lines.push(`  ${command.scope}/${command.source}: ${command.path}`);
    }
    appendDiagnostics(lines, outcome.diagnostics, options);
    return `${lines.join("\n")}\n`;
}
function formatHumanCommandInspection(inspection, options) {
    const { metadata } = inspection.command;
    const lines = [
        `Command: /${metadata.name}`,
        `scope/source: ${metadata.scope}/${metadata.source}`,
        `path: ${metadata.path}`,
        `description: ${metadata.description}`,
    ];
    if (metadata.argumentHint)
        lines.push(`argumentHint: ${metadata.argumentHint}`);
    if (metadata.allowedTools.length > 0) {
        lines.push(`allowedTools: ${metadata.allowedTools.join(", ")}`);
    }
    if (metadata.skills.length > 0)
        lines.push(`skills: ${metadata.skills.join(", ")}`);
    if (metadata.model)
        lines.push(`model: ${metadata.model}`);
    lines.push(`size: ${inspection.command.bytesRead}/${inspection.command.sizeBytes} bytes${inspection.command.truncated ? " (truncated)" : ""}`);
    if (options.verbose)
        lines.push("", "Content", inspection.command.content || "(empty)");
    appendDiagnostics(lines, inspection.diagnostics, options);
    return `${lines.join("\n")}\n`;
}
function formatCommandDescription(command) {
    const suffix = command.disableNonInteractive ? " (interactive only)" : "";
    return `${command.description}${suffix}`;
}
function appendDiagnostics(lines, diagnostics, options) {
    if (!options.verbose || diagnostics.length === 0)
        return;
    lines.push("", `Diagnostics (${diagnostics.length})`);
    for (const diagnostic of diagnostics) {
        const location = diagnostic.path ? ` (${diagnostic.path})` : "";
        lines.push(`- [${diagnostic.severity}] ${diagnostic.code}: ${diagnostic.message}${location}`);
    }
}
const formatCommandJson = (outcome, cwd) => formatJson({
    commands: outcome.commands.map(formatCommandMetadataJson),
    cwd,
    diagnostics: outcome.diagnostics.map(formatDiagnosticJson),
    totalDiscovered: outcome.totalDiscovered,
});
const formatCommandInspectionJson = (inspection, cwd) => formatJson({
    command: {
        bytesRead: inspection.command.bytesRead,
        content: inspection.command.content,
        metadata: formatCommandMetadataJson(inspection.command.metadata),
        sizeBytes: inspection.command.sizeBytes,
        truncated: inspection.command.truncated,
    },
    cwd,
    diagnostics: inspection.diagnostics.map(formatDiagnosticJson),
});
function formatCommandMetadataJson(command) {
    return {
        allowedTools: command.allowedTools,
        description: command.description,
        disableNonInteractive: command.disableNonInteractive,
        frontmatterKeys: command.frontmatterKeys,
        name: command.name,
        path: command.path,
        rootPath: command.rootPath,
        scope: command.scope,
        skills: command.skills,
        source: command.source,
        ...(command.argumentHint ? { argumentHint: command.argumentHint } : {}),
        ...(command.model ? { model: command.model } : {}),
    };
}
function formatDiagnosticJson(diagnostic) {
    return {
        code: diagnostic.code,
        message: diagnostic.message,
        ...(diagnostic.commandName ? { commandName: diagnostic.commandName } : {}),
        ...(diagnostic.path ? { path: diagnostic.path } : {}),
        severity: diagnostic.severity,
    };
}
