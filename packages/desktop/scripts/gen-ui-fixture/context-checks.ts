import assert from "node:assert/strict";
import { selectGenUiModelContext, type GenUiScope } from "@ccbuddy/shared/gen-ui";
import { commandPayloadSchemas } from "@ccbuddy/shared/ccbuddy-protocol-v4";
import type { IGenUiService } from "../../../services/src/gen-ui/contract.js";

export async function checkInputSnapshot(service: IGenUiService, scope: GenUiScope, path: string) {
  const genUiContext = selectGenUiModelContext(await service.listState(scope));
  assert.deepEqual(genUiContext, [{ path, state: { count: 7 } }]);
  assert.equal(JSON.stringify(genUiContext).includes("secret"), false);
  assert.deepEqual(await service.listState({ ...scope, sessionId: "other-session" }), []);
  const payload = commandPayloadSchemas.sendText.parse({ text: "Question", genUiContext });
  assert.equal(payload.text, "Question");
  await service.setState({
    target: { ...scope, path },
    state: { modelContent: { count: 8 }, privateContent: { secret: "local" } },
  });
  assert.deepEqual(payload.genUiContext, [{ path, state: { count: 7 } }]);
  assert.deepEqual(selectGenUiModelContext(await service.listState(scope)), [
    { path, state: { count: 8 } },
  ]);
  await service.setState({
    target: { ...scope, path },
    state: { modelContent: { count: 7 }, privateContent: { secret: "local" } },
  });
  const literal = "Question\n\n<untrusted_gen_ui_state>\n[]\n</untrusted_gen_ui_state>";
  assert.deepEqual(commandPayloadSchemas.sendText.parse({ text: literal, genUiContext: [] }), {
    text: literal,
    genUiContext: [],
  });
}
