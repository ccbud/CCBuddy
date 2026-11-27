import { formatJson } from "@ccbuddy/core";
import { loadBootstrapModule } from "./bootstrap-loader.js";
import { loadCliDotenv } from "./env.js";
export async function runLoginCommand(ctx, options, deps, noBrowser, args = []) {
    try {
        const providerId = args[0] ?? "zai";
        if (args.length > 1 || (providerId !== "zai" && providerId !== "bigmodel")) {
            throw new Error("Usage: ccbuddy login [zai|bigmodel] [--no-browser]");
        }
        const env = deps.env ?? process.env;
        const workingDirectory = (deps.cwd ?? process.cwd)();
        const dotenvResult = (deps.loadDotenv ?? loadCliDotenv)({
            cwd: workingDirectory,
            env,
        });
        if (dotenvResult.error) {
            throw new Error(`Failed to load environment file: ${dotenvResult.path}`, {
                cause: dotenvResult.error,
            });
        }
        const login = deps.loginCCbuddyCli ?? (await loadBootstrapModule()).loginCCbuddyCli;
        const result = await login({
            env,
            noBrowser,
            providerId,
            onAuthorizeUrl: (data) => {
                writeAuthorizeUrl(ctx, options, data.authorize_url, noBrowser, providerId);
            },
            onBrowserOpen: (browser) => {
                if (!options.json && !browser.opened) {
                    ctx.stdout.write(`Browser open failed: ${browser.reason ?? "unknown error"}\n`);
                }
            },
        });
        if (options.json) {
            ctx.stdout.write(formatJson({
                status: "ready",
                provider: result.providerId,
                user: {
                    user_id: result.user.user_id,
                    ...(result.user.email ? { email: result.user.email } : {}),
                    ...(result.user.name ? { name: result.user.name } : {}),
                    ...(result.user.avatar ? { avatar: result.user.avatar } : {}),
                },
                model: result.model,
                credentialsPath: result.credentialsPath,
                configPath: result.configPath,
                browserOpened: result.browser?.opened ?? false,
            }));
            return 0;
        }
        ctx.stdout.write([
            `Login successful${formatUserLabel(result.user)}.`,
            `Model: ${result.model}`,
            `Credentials: ${result.credentialsPath}`,
            `Model selection: ${result.configPath}`,
        ].join("\n") + "\n");
        return 0;
    }
    catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        ctx.stderr.write(`Error: ${message}\n`);
        if (options.verbose && error instanceof Error && error.stack) {
            ctx.stderr.write(`${error.stack}\n`);
        }
        return 1;
    }
}
export async function runLogoutCommand(ctx, options, deps) {
    try {
        const env = deps.env ?? process.env;
        const workingDirectory = (deps.cwd ?? process.cwd)();
        const dotenvResult = (deps.loadDotenv ?? loadCliDotenv)({
            cwd: workingDirectory,
            env,
        });
        if (dotenvResult.error) {
            throw new Error(`Failed to load environment file: ${dotenvResult.path}`, {
                cause: dotenvResult.error,
            });
        }
        const logout = deps.logoutCCbuddyCli ?? (await loadBootstrapModule()).logoutCCbuddyCli;
        const result = await logout({ env });
        if (options.json) {
            ctx.stdout.write(formatJson({
                status: "logged_out",
                provider: "zai",
                credentialsPath: result.credentialsPath,
            }));
            return 0;
        }
        ctx.stdout.write(`Logged out from Coding Plan accounts. Credentials: ${result.credentialsPath}\n`);
        return 0;
    }
    catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        ctx.stderr.write(`Error: ${message}\n`);
        if (options.verbose && error instanceof Error && error.stack) {
            ctx.stderr.write(`${error.stack}\n`);
        }
        return 1;
    }
}
function writeAuthorizeUrl(ctx, options, authorizeUrl, noBrowser, providerId) {
    const target = options.json ? ctx.stderr : ctx.stdout;
    if (noBrowser) {
        target.write(`Open this URL to sign in:\n${authorizeUrl}\n`);
        return;
    }
    target.write(`Opening browser for ${providerId === "bigmodel" ? "BigModel" : "Z.AI"} authorization.\nFallback URL:\n${authorizeUrl}\n`);
}
function formatUserLabel(user) {
    const label = user.name || user.email || user.user_id;
    return label ? ` as ${label}` : "";
}
