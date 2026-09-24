import { cn } from "@/components/lib/utils.js";
import ccbuddyIcon from "@/assets/ccbuddy-icon.png";

/** Display CCbuddy's original sprout-and-CC artwork throughout the app. */
export function CCbuddyAboutLogo({ className }: { className?: string }) {
  return <img src={ccbuddyIcon} className={cn("shrink-0", className)} alt="" aria-hidden="true" />;
}

export function CCbuddyWordmarkLogo({ className }: { className?: string }) {
  return (
    <span className={cn("inline-flex shrink-0 items-center gap-2 text-current", className)}>
      <img src={ccbuddyIcon} className="size-10" alt="" aria-hidden="true" />
      <span className="text-3xl font-bold">CCbuddy</span>
    </span>
  );
}
