import { useEffect, useRef, useState } from "react";
import { Alert, AlertDescription } from "./components/ui/alert.js";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "./components/ui/alert-dialog.js";
import { Button } from "./components/ui/button.js";
import { DesktopOverlayWindowControls } from "@/DesktopOverlayWindowControls.js";
import { CCbuddyAboutLogo } from "@/components/ui/CCbuddyAboutLogo.js";
import { useCCbuddyIntl } from "@/i18n/IntlProvider.js";
import type { useCredentialStoreRecovery } from "@/hooks/useCredentials.js";

export function CredentialStoreRecovery({
  recovery,
}: {
  recovery: ReturnType<typeof useCredentialStoreRecovery>;
}) {
  const { intl } = useCCbuddyIntl();
  const [confirming, setConfirming] = useState(false);
  const text = (id: Parameters<typeof intl.formatMessage>[0]["id"]) => intl.formatMessage({ id });
  return (
    <main
      data-testid="credential-store-recovery"
      className="relative flex min-h-dvh items-center justify-center bg-background p-4 text-foreground"
    >
      <DesktopOverlayWindowControls />
      <section className="w-full max-w-md space-y-4 rounded-2xl border border-popover-border bg-background p-6 text-ui-base shadow-md">
        <h1 className="text-ui-lg font-semibold">{text("login.credentialStore.title")}</h1>
        <p className="text-foreground-subtle">
          {text(
            recovery.state?.status === "recovered"
              ? "login.credentialStore.done"
              : recovery.state?.status === "changed"
                ? "login.credentialStore.changed"
                : "login.credentialStore.description",
          )}
        </p>
        {recovery.state?.status === "recovered" && (
          <p className="break-all text-ui-sm text-foreground-subtle">{recovery.state.backupPath}</p>
        )}
        {recovery.failed && (
          <Alert variant="destructive" data-testid="credential-store-recovery-error">
            <AlertDescription>{text("login.credentialStore.failed")}</AlertDescription>
          </Alert>
        )}
        {recovery.state?.status === "corrupt" ? (
          <Button
            data-testid="credential-store-recovery-open"
            disabled={recovery.busy}
            onClick={() => setConfirming(true)}
          >
            {text("login.credentialStore.restore")}
          </Button>
        ) : (
          <Button
            data-testid="credential-store-recovery-reload"
            onClick={() => window.location.reload()}
          >
            {text("login.credentialStore.reload")}
          </Button>
        )}
      </section>
      <AlertDialog
        open={confirming}
        onOpenChange={(open) => {
          if (!recovery.busy) setConfirming(open);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{text("login.credentialStore.restore")}</AlertDialogTitle>
            <AlertDialogDescription>{text("login.credentialStore.confirm")}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel
              data-testid="credential-store-recovery-cancel"
              disabled={recovery.busy}
            >
              {text("common.cancel")}
            </AlertDialogCancel>
            <Button
              variant="destructive"
              data-testid="credential-store-recovery-confirm"
              disabled={recovery.busy}
              onClick={async () => {
                await recovery.recover();
                setConfirming(false);
              }}
            >
              {text("login.credentialStore.restore")}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </main>
  );
}

export type LoginCompleteReason = "oauth" | "apiKey" | "skip";

/** The inherited cloud-account gate is bypassed for CCbuddy's local BYOK product. */
export function WelcomeScreen({
  onComplete,
}: {
  onComplete: (reason: LoginCompleteReason) => void | Promise<void>;
}) {
  const { locale } = useCCbuddyIntl();
  const completed = useRef(false);

  useEffect(() => {
    if (completed.current) return;
    completed.current = true;
    void onComplete("skip");
  }, [onComplete]);

  return (
    <main className="flex h-full min-h-dvh items-center justify-center bg-background text-foreground">
      <div className="flex flex-col items-center gap-4 text-center">
        <CCbuddyAboutLogo className="size-12" />
        <h1 className="text-xl font-semibold">CCbuddy</h1>
        <p className="text-ui-base text-foreground-subtle">
          {locale === "zh-CN" ? "正在打开本地工作区…" : "Opening your local workspace…"}
        </p>
      </div>
    </main>
  );
}
