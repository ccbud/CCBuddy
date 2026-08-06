/*
 * Monitor feed — subscribed at BOOT (not at view mount) so requests forwarded before the
 * 监控 view is first opened still count. No DOM work here: stats accumulate into shared
 * state and rows buffer (bounded) until the view mounts and drains them.
 */
import { api } from '../../core/bridge.js';
import { fmtTime } from '../../core/dom.js';
import { state } from '../../core/state.js';

const pendingRows = [];
const pendingLogs = [];
let rowSink = null;
let logSink = null;

function onRequestRow(r) {
  state.stats.total++;
  if (r.status >= 200 && r.status < 400) state.stats.ok++;
  state.stats.sumMs += r.ms || 0;
  state.stats.last = fmtTime();
  if (rowSink) rowSink(r);
  else {
    pendingRows.push(r);
    while (pendingRows.length > 100) pendingRows.shift(); // match the backend's capture buffer
  }
}

function onLogLine(l) {
  if (logSink) logSink(l);
  else {
    pendingLogs.push(l);
    while (pendingLogs.length > 100) pendingLogs.shift();
  }
}

let inited = false;
/** Called once from boot. Safe to call again (no-op). */
export function initMonitorFeed() {
  if (inited) return;
  inited = true;
  api.onRequest(onRequestRow);
  api.onLog(onLogLine);
}

/** The mounted monitor view takes over: replay what buffered, then stream live. */
export function attachMonitorSinks(onRow, onLog) {
  pendingRows.splice(0).forEach((r) => onRow(r, true));
  pendingLogs.splice(0).forEach((l) => onLog(l));
  rowSink = onRow;
  logSink = onLog;
}
