import type { HelpAppConfig } from "@ccbuddy/shared";

const CCBUDDY_REPOSITORY_URL = "https://github.com/ccbud/CCBuddy";

/** Help links are CCbuddy-owned and do not require the inherited cloud config endpoint. */
export function createDesktopHelpConfigReader(): () => Promise<HelpAppConfig> {
  return async () => ({
    community_urls: {
      "zh-CN": CCBUDDY_REPOSITORY_URL,
      "en-US": CCBUDDY_REPOSITORY_URL,
    },
    feedback_url: `${CCBUDDY_REPOSITORY_URL}/issues/new/choose`,
    feedback_use_external_form: true,
  });
}
