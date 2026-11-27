import { loadBootstrapModule } from "./bootstrap-loader.js";
export const resolveResumeSession = async (request, workingDirectory, env, deps) => {
    if (request.resumeSessionId) {
        return request.resumeSessionId;
    }
    if (!request.continueSession) {
        return undefined;
    }
    const resolveLatest = deps.resolveLatestSession ?? (await loadBootstrapModule()).resolveLatestSession;
    const latest = await resolveLatest({
        directory: workingDirectory,
        env,
    });
    if (!latest) {
        throw new Error(`No resumable session found for ${workingDirectory}`);
    }
    return latest.id;
};
