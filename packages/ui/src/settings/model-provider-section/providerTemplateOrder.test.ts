import { describe, expect, it } from "vitest";
import { sortProviderTemplatesForPicker } from "./providerTemplateOrder.js";

describe("sortProviderTemplatesForPicker", () => {
  it("puts DeepSeek, Alibaba Model Studio and Zhipu first and keeps the rest in file order", () => {
    const ids = [
      "zai-api",
      "zai-standard-api",
      "bigmodel-api",
      "bigmodel-standard-api",
      "moonshot-kimi",
      "minimax",
      "deepseek",
      "qwen-alibaba-model-studio-cn",
      "qwen-alibaba-model-studio-intl",
      "xiaomi-mimo",
      "openai",
    ];
    const sorted = sortProviderTemplatesForPicker(ids.map((templateId) => ({ templateId })));
    expect(sorted.map((template) => template.templateId)).toEqual([
      "deepseek",
      "qwen-alibaba-model-studio-cn",
      "qwen-alibaba-model-studio-intl",
      "bigmodel-api",
      "zai-api",
      "bigmodel-standard-api",
      "zai-standard-api",
      "moonshot-kimi",
      "minimax",
      "xiaomi-mimo",
      "openai",
    ]);
  });

  it("ignores preferred ids that are not present", () => {
    const sorted = sortProviderTemplatesForPicker([{ templateId: "openai" }]);
    expect(sorted).toEqual([{ templateId: "openai" }]);
  });
});
