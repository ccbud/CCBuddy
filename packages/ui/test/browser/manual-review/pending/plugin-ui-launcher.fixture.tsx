import { useState } from "react";
import { createRoot } from "react-dom/client";
import { PluginUiToolCallView } from "@/plugin-ui/components/PluginUiToolCallBlock.js";
import { CCbuddyIntlProvider, useCCbuddyIntl } from "@/i18n/IntlProvider.js";
import "@/styles.css";

const params = new URLSearchParams(location.search);
document.documentElement.className = `${params.get("theme")} theme-zai-${params.get("theme")}`;
function Fixture() {
  const [opened, setOpened] = useState(false);
  const { intl } = useCCbuddyIntl();
  const label = (id: string) => intl.formatMessage({ id });
  return (
    <main className="min-h-screen bg-background p-4 text-foreground">
      <div className="mx-auto max-w-2xl">
        <PluginUiToolCallView
          supported
          fallback={null}
          preferredDisplayMode="fullscreen"
          sidePaneActive={opened}
          inlineAllowed={false}
          pluginId="pdf@ccbuddy-plugins-official"
          pluginName={
            params.get("long")
              ? "PDF — Research document with a very long descriptive title"
              : "PDF"
          }
          host={{
            pageKey: "fixture",
            handle: null,
            phase: "running",
            height: 240,
            error: null,
            reload() {},
          }}
          prefersBorder
          superseded={false}
          pinLabel={label("pluginUi.pin")}
          unpinLabel={label("pluginUi.unpin")}
          loadingLabel={label("pluginUi.loading")}
          errorLabel={label("pluginUi.loadFailed")}
          retryLabel={label("pluginUi.retry")}
          openedLabel={label("pluginUi.openedInSidePane")}
          openLabel={label("pluginUi.openInSidePane")}
          openButtonLabel={label("pluginUi.open")}
          onWidthChange={() => {}}
          onOpenSidePane={() => setOpened(true)}
        />
      </div>
    </main>
  );
}
createRoot(document.getElementById("root")!).render(
  <CCbuddyIntlProvider initialLocale={params.get("locale") === "zh-CN" ? "zh-CN" : "en-US"}>
    <Fixture />
  </CCbuddyIntlProvider>,
);
