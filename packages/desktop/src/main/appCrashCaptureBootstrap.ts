import { logger } from "./logger.js";
import { initializeCrashCapture, type CrashCapturePaths } from "./desktopCrashCapture.js";
import { armsRumEnabled } from "./armsRumAvailability.js";

// 须在 appARMSBootstrap 之前完成：先由 desktopEarlyDataBaseDirBootstrap 注入 dataBaseDir，再配置 crashDumps。
// 只有实际启用 ARMS 时才跳过仅本地的 crashReporter；未配置端点仍须生成本地 dump。
export const crashCapturePaths: CrashCapturePaths = initializeCrashCapture(logger, armsRumEnabled);
