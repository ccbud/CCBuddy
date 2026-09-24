export const CLI_COMMAND_NAME = "ccbuddy";
export const CLI_PROCESS_NAME = "ccbuddy-cli";

interface ProcessTitleTarget {
  title: string;
}

export const setCliProcessTitle = (
  target: ProcessTitleTarget = process,
): void => {
  target.title = CLI_PROCESS_NAME;
};
