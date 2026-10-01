/**
 * 供应商模板不按厂商分组：所有模板同等对待，只把这里列出的排在最前（按此顺序），
 * 其余保持内置模板文件的原有顺序。
 */
export const PREFERRED_PROVIDER_TEMPLATE_ORDER: readonly string[] = [
  "deepseek",
  "qwen-alibaba-model-studio-cn",
  "qwen-alibaba-model-studio-intl",
  "bigmodel-api",
  "zai-api",
  "bigmodel-standard-api",
  "zai-standard-api",
];

export function sortProviderTemplatesForPicker<T extends { templateId: string }>(
  templates: readonly T[],
): T[] {
  const preferred = PREFERRED_PROVIDER_TEMPLATE_ORDER.flatMap((templateId) =>
    templates.filter((template) => template.templateId === templateId),
  );
  const rest = templates.filter(
    (template) => !PREFERRED_PROVIDER_TEMPLATE_ORDER.includes(template.templateId),
  );
  return [...preferred, ...rest];
}
