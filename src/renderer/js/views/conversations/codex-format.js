/* Harness-injected content normalization for user turns (Codex bootstrap, reminders, commands). */

// Codex records its initial AGENTS instructions and environment snapshot as two text blocks in
// one user message. Turn that XML-ish transport shape into compact Markdown for the transcript.
export function formatCodexBootstrap(text) {
  const source = String(text || '');
  const agents = /^\s*#\s+AGENTS\.md instructions for ([^\r\n]+)[\s\S]*?<INSTRUCTIONS\b[^>]*>([\s\S]*?)<\/INSTRUCTIONS>/i.exec(source);
  if (!agents) return null;

  const env = /<environment_context\b[^>]*>([\s\S]*?)<\/environment_context>/i.exec(source);
  const parts = ['# AGENTS.md instructions for ' + agents[1].trim()];
  const instructions = agents[2].trim();
  if (instructions) {
    const lines = instructions.split(/\r?\n/).filter((line) => line.trim());
    parts.push(lines.length === 1
      ? '**INSTRUCTIONS:** ' + lines[0].trim()
      : '**INSTRUCTIONS:**\n\n' + instructions);
  }

  if (env) {
    const block = env[1];
    const tag = (name) => {
      const match = new RegExp('<' + name + '\\b[^>]*>([\\s\\S]*?)<\\/' + name + '>', 'i').exec(block);
      return match ? match[1].trim() : '';
    };
    const attr = (name, attribute) => {
      const match = new RegExp("<" + name + "\\b[^>]*\\b" + attribute + "=[\"']([^\"']+)[\"']", "i").exec(block);
      return match ? match[1].trim() : '';
    };
    const code = (value) => {
      const tick = String.fromCharCode(96);
      return value ? tick + value + tick : '';
    };
    const roots = [];
    const rootRe = /<root\b[^>]*>([\s\S]*?)<\/root>/gi;
    let root;
    while ((root = rootRe.exec(block)) !== null) {
      if (root[1].trim()) roots.push(code(root[1].trim()));
    }
    const fields = [
      ['environment_context', code(tag('cwd'))],
      ['shell', tag('shell')],
      ['current_date', tag('current_date')],
      ['timezone', tag('timezone')],
      ['workspace_roots', roots.join(', ')],
      ['permission_profile', attr('permission_profile', 'type')],
      ['file_system', attr('file_system', 'type')],
    ].filter((field) => field[1]);
    if (fields.length) {
      parts.push(fields.map((field) => '**' + field[0] + ':** ' + field[1]).join('  \n'));
    }
  }

  let rest = source.replace(agents[0], '');
  if (env) rest = rest.replace(env[0], '');
  rest = rest.trim();
  if (rest) parts.push(rest);
  return parts.join('\n\n').trim();
}

// Strip harness-injected blocks from user turns while keeping their human-facing content.
// A task notification is an XML envelope whose <result> is the actual Markdown response;
// its IDs, status, summary, usage, and other transport metadata are not useful in the thread.
// Codex normalization turns a standalone <skill> envelope into a neutral `skill_load` card.
// Keep this raw-envelope suppression only as a legacy fallback, so it can never leak into a
// user bubble when older/imported data bypasses that normalizer.
// Returns '' when a turn contains injected metadata only.
export function stripInjected(text) {
  let source = String(text || '');
  const bootstrap = formatCodexBootstrap(source);
  if (bootstrap != null) source = bootstrap;
  // Only suppress the standalone Codex injection. Keep ordinary prose intact when a user is
  // discussing or quoting <skill> markup alongside their own text.
  if (/^\s*<skill\b[^>]*>[\s\S]*<\/skill>\s*$/i.test(source)) return '';
  return source
    .replace(/<task-notification\b[^>]*>[\s\S]*?<\/task-notification>/gi, (block) => {
      const result = /<result\b[^>]*>([\s\S]*?)<\/result>/i.exec(block);
      return result ? `\n${result[1].trim()}\n` : '';
    })
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '')
    .replace(/<command-[a-z-]+>[\s\S]*?<\/command-[a-z-]+>/g, '')
    .replace(/<local-command-[a-z]+>[\s\S]*?<\/local-command-[a-z]+>/g, '')
    .trim();
}
