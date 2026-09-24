import { Worker } from "node:worker_threads";

import {
  isCCbuddyDataSizeScanResult,
  type CCbuddyDataSizeScanRequest,
  type CCbuddyDataSizeScanResult,
} from "./ccbuddyDataSizeScanner.js";

export function scanCCbuddyDataDirectoryInWorker(
  request: CCbuddyDataSizeScanRequest,
  signal: AbortSignal,
): Promise<CCbuddyDataSizeScanResult> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./ccbuddyDataSizeWorker.js", import.meta.url), {
      workerData: request,
    });
    let settled = false;

    const finish = (run: () => void) => {
      if (settled) {
        return;
      }
      settled = true;
      signal.removeEventListener("abort", abort);
      run();
    };
    const abort = () => {
      void worker.terminate();
      finish(() => reject(new DOMException("CCbuddy data size scan aborted", "AbortError")));
    };

    worker.once("message", (message: unknown) => {
      const response = message as { ok?: unknown; result?: unknown; error?: unknown };
      if (response.ok === true && isCCbuddyDataSizeScanResult(response.result)) {
        finish(() => resolve(response.result as CCbuddyDataSizeScanResult));
        return;
      }
      finish(() =>
        reject(
          new Error(
            response.ok === false && typeof response.error === "string"
              ? response.error
              : "Invalid CCbuddy data size worker response",
          ),
        ),
      );
    });
    worker.once("error", (error) => finish(() => reject(error)));
    worker.once("exit", (code) => {
      if (code !== 0) {
        finish(() => reject(new Error(`CCbuddy data size worker exited with code ${code}`)));
      }
    });
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) {
      abort();
      return;
    }
    worker.unref();
  });
}
