import { statSync } from "node:fs";
import { resolve } from "node:path";
const CWD_OPTION_LABEL = "--cwd";
export function resolveCliCwd(options) {
    const baseDirectory = options.cwd();
    if (options.requestedCwd === undefined)
        return baseDirectory;
    if (options.requestedCwd.length === 0) {
        throw new Error(`${CWD_OPTION_LABEL} requires a non-empty path.`);
    }
    const workingDirectory = resolve(baseDirectory, options.requestedCwd);
    let stats;
    try {
        stats = statSync(workingDirectory);
    }
    catch (error) {
        throw new Error(`${CWD_OPTION_LABEL} path is not accessible: ${workingDirectory}`, {
            cause: error,
        });
    }
    if (!stats.isDirectory()) {
        throw new Error(`${CWD_OPTION_LABEL} must point to a directory: ${workingDirectory}`);
    }
    return workingDirectory;
}
