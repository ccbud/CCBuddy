import type { CCbuddyConfigOption } from "@ccbuddy/shared";

export function applySelectedCCbuddyMode(
  options: readonly CCbuddyConfigOption[],
  mode: string,
): CCbuddyConfigOption[] {
  const normalizedMode = mode.trim();
  if (!normalizedMode) {
    return [...options];
  }

  let changed = false;
  const nextOptions = options.map((option) => {
    if (option.category !== "mode" || option.type !== "select") {
      return option;
    }

    const hasModeOption = Boolean(
      option.options?.some((candidate) => candidate.value === normalizedMode),
    );
    if (!hasModeOption || option.currentValue === normalizedMode) {
      return option;
    }

    changed = true;
    return {
      ...option,
      currentValue: normalizedMode,
    };
  });

  return changed ? nextOptions : [...options];
}
