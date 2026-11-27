import {
  DEFAULT_FEEDBACK_TICKET_FRAMEWORK,
  type CCbuddyProvider,
  type FeedbackTicketFramework,
} from "@ccbuddy/shared";

export function inferFeedbackFrameworkFromAgentProvider(
  _provider: CCbuddyProvider | null | undefined,
): FeedbackTicketFramework {
  return DEFAULT_FEEDBACK_TICKET_FRAMEWORK;
}
