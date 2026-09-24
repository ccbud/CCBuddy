import type { ReactNode } from "react";
import { CCbuddyAboutLogo } from "@/components/ui/CCbuddyAboutLogo.js";

interface RootStartupLoadingProps {
  label: string;
  children?: ReactNode;
  busy?: boolean;
}

export function RootStartupLoading({ label, children, busy = true }: RootStartupLoadingProps) {
  return (
    <div
      // Web 端全局 html/body/#root 为 Electron 透明背景让路，React 接管后会替换 HTML 启动壳。
      // 这里必须由阻塞态自身承接主题背景，否则远控链接会在 Root 恢复期间继续露出浏览器白底。
      className="flex h-full min-h-dvh flex-col items-center justify-center gap-6 bg-background text-foreground"
      role="status"
      aria-busy={busy}
      aria-label={label}
      data-testid="root-startup-loading"
    >
      <CCbuddyStartupLogoBadge />
      {children}
    </div>
  );
}

/** 初始化与引导共用品牌图标；图片铺满圆角徽章，避免旧版双层图标显得过小。 */
export function CCbuddyStartupLogoBadge({ animated = true }: { animated?: boolean }) {
  return (
    <div className="relative size-24 overflow-hidden rounded-3xl bg-[#2b2d2c] shadow-xl/20 before:pointer-events-none before:absolute before:inset-0 before:rounded-[inherit] before:border before:border-[rgba(255,255,255,0.1)] before:content-['']">
      <CCbuddyAboutLogo className={`size-full object-cover ${animated ? "animate-pulse" : ""}`} />
    </div>
  );
}
