cask "ccbud" do
  version "1.3.9"
  sha256 "0a70fd7cad32126460341f9cd85a177d151f67ab9dbb62b60796dd85874601cb"

  url "https://github.com/ccbud/ccbud/releases/download/v#{version}/CC.Buddy_#{version}_aarch64.dmg",
      verified: "github.com/ccbud/ccbud/"
  name "CC Buddy"
  desc "CC Buddy — Claude Code gateway plus Claude Code/Codex session browser"
  homepage "https://github.com/ccbud/ccbud"

  # CC Buddy can update itself in-app; Homebrew handles normal cask upgrades.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :ventura

  app "CC Buddy.app"

  zap trash: [
    "~/Library/Application Support/ccbud",
    "~/Library/Preferences/dev.ccbud.gateway.plist",
    "~/Library/Saved Application State/dev.ccbud.gateway.savedState",
    "~/Library/Logs/ccbud",
  ]
end
