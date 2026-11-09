import { expandCustomCommandPrompt } from "@ccbuddy/contracts";
import {
  loadCCbuddyCustomCommand,
  type ListCCbuddyCustomCommandsOptions,
} from "./custom-commands.js";
import { isReservedCCbuddySlashCommandName } from "./slash-command-surface.js";

const CUSTOM_COMMAND_NOT_FOUND_PATTERN = /not found/i;
const PROMPT_CUSTOM_COMMAND_PATTERN = /^\/([^\s]+)(?:\s+([\s\S]*))?$/;

export async function resolveCCbuddyCustomCommandPrompt(
  input: string,
  options: ListCCbuddyCustomCommandsOptions = {},
): Promise<string | undefined> {
  const invocation = parsePromptCustomCommandInvocation(input);
  // 保留名（含内置 `workflow`）在这里直接返回 undefined，与「命令不存在」同形：内置命令由
  // builtin-prompt-command.ts 先行展开，这里拒绝的是借同名自定义命令绕过内置语义（或灰度门）的路径。
  if (!invocation || isReservedCCbuddySlashCommandName(invocation.name)) {
    return undefined;
  }

  try {
    const command = await loadCCbuddyCustomCommand({
      ...options,
      name: invocation.name,
    });
    // 解析只改写文本：`!` 块交给模型经 Bash 工具执行，见 contracts 的 handOffCustomCommandShellBlocks。
    return expandCustomCommandPrompt({
      args: invocation.args,
      command,
    }).prompt;
  } catch (error) {
    if (error instanceof Error && CUSTOM_COMMAND_NOT_FOUND_PATTERN.test(error.message)) {
      return undefined;
    }
    throw error;
  }
}

function parsePromptCustomCommandInvocation(input: string): { args: string; name: string } | null {
  const match = PROMPT_CUSTOM_COMMAND_PATTERN.exec(input.trim());
  if (!match?.[1]) {
    return null;
  }
  return {
    args: match[2]?.trim() ?? "",
    name: match[1].toLowerCase(),
  };
}
