import { isMainThread, parentPort, workerData } from "node:worker_threads";

import {
  scanCCbuddyDataDirectory,
  type CCbuddyDataSizeScanRequest,
} from "./ccbuddyDataSizeScanner.js";

type WorkerResponse =
  | { ok: true; result: Awaited<ReturnType<typeof scanCCbuddyDataDirectory>> }
  | { ok: false; error: string };

const workerParentPort = parentPort;
if (!isMainThread && workerParentPort) {
  void scanCCbuddyDataDirectory(workerData as CCbuddyDataSizeScanRequest)
    .then((result) => {
      workerParentPort.postMessage({ ok: true, result } satisfies WorkerResponse);
    })
    .catch((error) => {
      workerParentPort.postMessage({
        ok: false,
        error: error instanceof Error ? error.message : "unknown worker error",
      } satisfies WorkerResponse);
    });
}
