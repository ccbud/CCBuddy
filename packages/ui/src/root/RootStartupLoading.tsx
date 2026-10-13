import type { ReactNode } from "react";
import { CCbuddyAboutLogo } from "@/components/ui/CCbuddyAboutLogo.js";
import { cn } from "@/components/lib/utils.js";

interface RootStartupLoadingProps {
  label: string;
  children?: ReactNode;
  busy?: boolean;
}

export function RootStartupLoading({ label, children, busy = true }: RootStartupLoadingProps) {
  return (
    <div
      // Web 端全局 html/body/#root 为 Electron 透明背景让路，React 接管后会替换 HTML 启动壳。
      // 这里必须由阻塞态自身承接主题背景，否则普通 Web 会在 Root 恢复期间露出浏览器白底。
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

/** 初始化与引导共用品牌图标，保持底色、描边、圆角和标志比例一致。 */
export function CCbuddyStartupLogoBadge({ animated = true }: { animated?: boolean }) {
  return (
    <div className="relative size-24 overflow-hidden rounded-3xl bg-[#2b2d2c] shadow-xl/20 before:pointer-events-none before:absolute before:inset-0 before:rounded-[inherit] before:border before:border-[rgba(255,255,255,0.1)] before:content-['']">
      <CCbuddyStartupLogo className="size-full object-cover" animated={animated} />
    </div>
  );
}

export function CCbuddyStartupLogo({
  className,
  animated = true,
}: {
  className?: string;
  animated?: boolean;
}) {
  // 修复原因：上游同步把自有图标替换成了 Z 形 SVG；统一复用已随包提供的 CCbuddy 资源。
  return (
    <CCbuddyAboutLogo
      className={cn(
        className,
        animated &&
          "motion-safe:animate-pulse motion-safe:[animation-delay:3s] motion-safe:[animation-duration:1.8s]",
      )}
    />
  );
}
