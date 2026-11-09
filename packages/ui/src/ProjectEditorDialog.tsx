import { useState } from "react";
import type { SaveProjectInput, VirtualProject } from "@ccbuddy/services";
import { useCCbuddyIntl } from "@/i18n/IntlProvider.js";
import { Button } from "@/components/ui/button.js";
import { Input } from "@/components/ui/input.js";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog.js";

export function ProjectEditorDialog({
  project,
  busy,
  error,
  onSave,
  onClose,
}: {
  error: string | null;
  project: VirtualProject | null;
  busy: boolean;
  onSave(input: SaveProjectInput): Promise<unknown>;
  onClose(): void;
}) {
  const { intl } = useCCbuddyIntl();
  const message = (key: string) => intl.formatMessage({ id: `projectManager.${key}` });
  const [name, setName] = useState(project?.name ?? "");
  const [roots, setRoots] = useState(project?.roots.map((root) => root.rootPath).join("\n") ?? "");
  const [primary, setPrimary] = useState(
    project?.roots.find((root) => root.isPrimary)?.rootPath ?? "",
  );
  const paths = [
    ...new Set(
      roots
        .split("\n")
        .map((path) => path.trim())
        .filter(Boolean),
    ),
  ];
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
    >
      <DialogContent data-testid="project-editor">
        <DialogHeader>
          <DialogTitle>{message(project ? "edit" : "create")}</DialogTitle>
          <DialogDescription>{message("description")}</DialogDescription>
        </DialogHeader>
        {error && (
          <div role="alert" className="break-words text-ui-caption text-destructive">
            {error}
          </div>
        )}
        <form
          className="flex flex-col gap-3 text-ui-base"
          onSubmit={(event) => {
            event.preventDefault();
            void onSave({
              id: project?.id,
              name: name.trim(),
              roots: paths,
              primaryRoot: paths.includes(primary) ? primary : paths[0],
            }).then((saved) => {
              if (saved) onClose();
            });
          }}
        >
          <label className="flex flex-col gap-1">
            {message("name")}
            <Input
              required
              autoFocus
              value={name}
              onChange={(event) => setName(event.target.value)}
              data-testid="project-name"
            />
          </label>
          <label className="flex flex-col gap-1">
            {message("roots")}
            <textarea
              className="min-h-24 rounded-md border border-input bg-background p-2 text-ui-base"
              value={roots}
              onChange={(event) => setRoots(event.target.value)}
              data-testid="project-roots"
            />
          </label>
          <label className="flex flex-col gap-1">
            {message("primary")}
            <select
              className="rounded-md border border-input bg-background p-2 text-ui-base"
              value={paths.includes(primary) ? primary : (paths[0] ?? "")}
              onChange={(event) => setPrimary(event.target.value)}
              data-testid="project-primary"
            >
              {paths.map((path) => (
                <option key={path} value={path}>
                  {path}
                </option>
              ))}
            </select>
          </label>
          <DialogFooter>
            <Button type="button" variant="ghost" disabled={busy} onClick={onClose}>
              {message("cancel")}
            </Button>
            <Button type="submit" disabled={busy || !name.trim()} data-testid="project-save">
              {message("save")}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
