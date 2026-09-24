import { useCCbuddyIntl } from "../i18n/IntlProvider.js";
import { usePlatform } from "../hooks/usePlatform.js";
import { HistoryReviewController, type HistoryReadBridge } from "./HistoryReviewController.js";

export function HistoryMainView({
  view,
  onViewChange,
}: {
  view: "list" | "timeline";
  onViewChange: (view: "list" | "timeline") => void;
}) {
  const { locale } = useCCbuddyIntl();
  const platform = usePlatform();
  const bridge = platform.historyReview;
  if (!bridge || bridge.protocolVersion !== 1) {
    return (
      <div
        className="flex h-full items-center justify-center bg-background text-foreground"
        role="alert"
      >
        {locale === "zh-CN" ? "此设备无法读取会话历史。" : "Session history is unavailable."}
      </div>
    );
  }
  return (
    <HistoryReviewController
      history={bridge as HistoryReadBridge}
      view={view}
      onViewChange={onViewChange}
      locale={locale}
    />
  );
}
