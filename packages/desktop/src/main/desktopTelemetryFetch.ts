export interface DesktopTelemetryFetchSource {
  fetch: (input: string | Request, init?: RequestInit) => Promise<Response>;
}

export function createDesktopTelemetryFetch(source: DesktopTelemetryFetchSource): typeof fetch {
  // 标准 Fetch 接受 URL，但 Electron net.fetch 只接受字符串或 Request；边界处统一序列化。
  return (input, init) => source.fetch(input instanceof URL ? input.toString() : input, init);
}
