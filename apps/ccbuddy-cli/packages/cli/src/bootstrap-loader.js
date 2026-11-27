let bootstrapModulePromise;
export const loadBootstrapModule = () => {
    bootstrapModulePromise ??= import("@ccbuddy/bootstrap");
    return bootstrapModulePromise;
};
