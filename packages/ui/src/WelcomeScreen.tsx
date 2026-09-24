import { useEffect, useRef } from "react";
import { CCbuddyAboutLogo } from "@/components/ui/CCbuddyAboutLogo.js";
import { useCCbuddyIntl } from "@/i18n/IntlProvider.js";

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
