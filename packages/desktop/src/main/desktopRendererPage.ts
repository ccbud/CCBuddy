export type DesktopRendererPage = "index" | "login";

export function resolveRendererDevUrl(base: string, page: DesktopRendererPage): URL {
  return new URL(page === "index" ? "" : `${page}.html`, base);
}

export function rendererHtmlFileName(page: DesktopRendererPage): string {
  return `${page}.html`;
}
