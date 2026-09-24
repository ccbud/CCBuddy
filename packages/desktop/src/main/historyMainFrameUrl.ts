/** History reads must stay bound to the application renderer entry, not a later navigation. */
export function isTrustedHistoryMainFrameUrl(actualUrl: string, expectedUrl: string): boolean {
  try {
    const actual = new URL(actualUrl);
    const expected = new URL(expectedUrl);
    const windowKinds = actual.searchParams.getAll("windowKind");
    return (
      actual.protocol === expected.protocol &&
      actual.host === expected.host &&
      actual.pathname === expected.pathname &&
      (windowKinds.length === 0 || (windowKinds.length === 1 && windowKinds[0] === "main"))
    );
  } catch {
    return false;
  }
}
