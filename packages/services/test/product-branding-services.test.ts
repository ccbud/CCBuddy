import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { test } from "node:test";
import { formatBotMessage } from "../src/bots/messages.ts";
import { createCredentialService } from "../src/credential/credentialService.ts";
import { createFeedbackDiagnosticArchive } from "../src/feedback/feedbackLogArchive.ts";
import { buildCheckpointEnv } from "../src/git/repo/gitCheckpointHelpers.ts";
import { setDataBaseDir } from "../src/paths.ts";
import { OffPeakCredentialsUnavailableError } from "../src/session/offPeakRuntimeModel.ts";
import { CCbuddyProtocolRequestTimeoutError } from "../src/ccbuddy-agent/ccbuddyProtocolClient.ts";

test("service errors and diagnostic archive identify as CCbuddy", async () => {
  const home = await mkdtemp(join(tmpdir(), "ccbuddy-service-branding-"));
  try {
    setDataBaseDir(home);
    await mkdir(join(home, ".ccbuddy", "v2", "credentials.json"), { recursive: true });
    const credentials = createCredentialService({
      cipherProvider: { encrypt: (value) => value, decrypt: (value) => value },
    });
    await assert.rejects(credentials.load("test"), /CCbuddy credentials/);

    const timeout = new CCbuddyProtocolRequestTimeoutError("session/create", 1, 1000);
    assert.match(timeout.message, /^CCbuddy Protocol request timed out:/);

    const archive = await createFeedbackDiagnosticArchive({ sources: [], outputRootDir: home });
    assert.equal(basename(archive.path), "ccbuddy-diagnostic-logs.zip");
  } finally {
    setDataBaseDir(null);
    await rm(home, { recursive: true, force: true });
  }
});

test("bot replies, model errors, and checkpoint commits identify as CCbuddy", () => {
  for (const locale of ["zh-CN", "en-US"] as const) {
    for (const id of ["userNotBound", "helpTitle", "remoteReconnectUnavailable"] as const) {
      const message = formatBotMessage(locale, id, { workspacePath: "/tmp/workspace" });
      assert.match(message, /CCbuddy/);
      assert.doesNotMatch(message, /ccbuddy/i);
    }
  }

  assert.match(new OffPeakCredentialsUnavailableError("jwt").message, /CCbuddy/);
  const checkpoint = buildCheckpointEnv("/tmp/index");
  assert.equal(checkpoint.GIT_AUTHOR_NAME, "CCbuddy Checkpoint");
  assert.equal(checkpoint.GIT_COMMITTER_NAME, "CCbuddy Checkpoint");
  assert.equal(checkpoint.GIT_AUTHOR_EMAIL, "checkpoint@ccbuddy.local");
  assert.equal(checkpoint.GIT_COMMITTER_EMAIL, "checkpoint@ccbuddy.local");
});
