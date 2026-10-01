import { useState, type ReactNode } from "react";
import { FolderOpen, FolderPlus, Trash2 } from "lucide-react";
import { Button } from "../components/ui/button.js";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "../components/ui/dialog.js";
import type { HistoryLocale, HistoryRootStatus, HistorySource } from "./contract.js";
import { HISTORY_SOURCES } from "./contract.js";
import { SourceDot } from "./HistorySessionList.js";
import { historyLabels, rootOriginLabel, sourceLabel } from "./labels.js";

export interface HistoryCustomRoot {
  source: HistorySource;
  path: string;
}

export interface HistoryRootsManagement {
  customRoots: readonly HistoryCustomRoot[];
  addRoot: (root: HistoryCustomRoot) => Promise<void>;
  removeRoot: (path: string) => Promise<void>;
  chooseDirectory: () => Promise<string | null>;
}

export interface HistoryRootsDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  roots: readonly HistoryRootStatus[];
  management: HistoryRootsManagement;
  locale: HistoryLocale;
}

function RootRow({
  root,
  locale,
  action,
}: {
  root: HistoryRootStatus;
  locale: HistoryLocale;
  action?: ReactNode;
}) {
  const labels = historyLabels(locale);
  return (
    <li className="flex items-center gap-2 py-1.5 text-ui-sm">
      <SourceDot source={root.source} />
      <span className="w-28 shrink-0 truncate text-foreground">{sourceLabel(root.source)}</span>
      <span
        className="min-w-0 flex-1 truncate font-mono text-ui-xs text-foreground-subtle"
        title={root.path}
      >
        {root.path}
      </span>
      <span className="shrink-0 rounded-full border border-border px-1.5 text-ui-xs text-foreground-subtle">
        {rootOriginLabel(root.origin, locale)}
      </span>
      <span
        className={`w-12 shrink-0 text-right text-ui-xs ${root.available ? "text-foreground-subtle" : "text-destructive"}`}
      >
        {root.available ? labels.rootAvailable : labels.rootMissing}
      </span>
      {action}
    </li>
  );
}

/** Lets the user see which folders the read-only scan covers and add their own. */
export function HistoryRootsDialog({
  open,
  onOpenChange,
  roots,
  management,
  locale,
}: HistoryRootsDialogProps) {
  const labels = historyLabels(locale);
  const [source, setSource] = useState<HistorySource>("claude");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const customPaths = new Set(management.customRoots.map((root) => root.path));
  const detected = roots.filter((root) => root.origin !== "custom");
  const custom = management.customRoots.map((root) => {
    const status = roots.find((item) => item.origin === "custom" && item.path === root.path);
    return status ?? { ...root, origin: "custom" as const, available: false };
  });

  async function run(task: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await task();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{labels.rootsTitle}</DialogTitle>
          <DialogDescription>{labels.rootsDescription}</DialogDescription>
        </DialogHeader>
        <div className="flex max-h-[60vh] flex-col gap-4">
          <section className="min-h-0 overflow-auto">
            <h3 className="mb-1 text-ui-xs font-medium text-foreground-subtle">
              {labels.rootsDetected}
            </h3>
            <ul className="divide-y divide-border/50">
              {detected.map((root) => (
                <RootRow key={`${root.source}:${root.path}`} root={root} locale={locale} />
              ))}
            </ul>
          </section>
          <section className="shrink-0">
            <h3 className="mb-1 text-ui-xs font-medium text-foreground-subtle">
              {labels.rootsCustom}
            </h3>
            {custom.length === 0 ? (
              <p className="py-1.5 text-ui-sm text-foreground-subtlest">
                {labels.rootsCustomEmpty}
              </p>
            ) : (
              <ul className="max-h-40 divide-y divide-border/50 overflow-auto">
                {custom.map((root) => (
                  <RootRow
                    key={root.path}
                    root={root}
                    locale={locale}
                    action={
                      <Button
                        type="button"
                        size="icon-sm"
                        variant="ghost"
                        aria-label={labels.removeRoot}
                        disabled={busy || !customPaths.has(root.path)}
                        onClick={() => void run(() => management.removeRoot(root.path))}
                      >
                        <Trash2 className="size-4" />
                      </Button>
                    }
                  />
                ))}
              </ul>
            )}
            <div className="mt-2 flex flex-wrap items-center gap-2">
              <label className="flex items-center gap-2 text-ui-sm text-foreground-subtle">
                {labels.rootSourceLabel}
                <select
                  value={source}
                  onChange={(event) => setSource(event.target.value as HistorySource)}
                  className="h-7 rounded-lg border border-input-border bg-input px-2 text-ui-sm text-foreground outline-none focus-visible:border-input-border-focused"
                >
                  {HISTORY_SOURCES.map((item) => (
                    <option key={item} value={item}>
                      {sourceLabel(item)}
                    </option>
                  ))}
                </select>
              </label>
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={busy}
                onClick={() =>
                  void run(async () => {
                    const path = await management.chooseDirectory();
                    if (!path || customPaths.has(path)) return;
                    await management.addRoot({ source, path });
                  })
                }
              >
                <FolderPlus className="size-4" />
                {labels.addRoot}
              </Button>
            </div>
            {error ? (
              <p role="alert" className="mt-2 text-ui-xs text-destructive">
                {error}
              </p>
            ) : null}
          </section>
        </div>
        <DialogFooter>
          <Button type="button" variant="secondary" size="sm" onClick={() => onOpenChange(false)}>
            <FolderOpen className="size-4" />
            {labels.close}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
