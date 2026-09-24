import assert from "node:assert/strict";
import test from "node:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ChatErrorBanner } from "./ChatErrorBanner.js";
import { CCbuddyIntlProvider } from "./i18n/IntlProvider.js";

test("missing model offers user-provider setup without an account upgrade", () => {
  const html = renderToStaticMarkup(
    <CCbuddyIntlProvider initialLocale="en-US">
      <ChatErrorBanner
        error={{ code: "MODEL_CONFIG_MISSING", message: "Model config is missing" }}
        onOpenModelSettings={() => {}}
      />
    </CCbuddyIntlProvider>,
  );
  assert.match(html, /Configure your own model service/);
  assert.match(html, /aria-label="Set"/);
  assert.doesNotMatch(html, /Upgrade|Sign in/);
});
