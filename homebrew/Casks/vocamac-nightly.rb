# Mirror of the cask published in VocaHQ/homebrew-vocamac, which is what
# `brew install --cask vocamac` actually reads. `update-homebrew-cask.yml`
# rewrites `version` and `sha256` in THAT repo on every release publish and
# never touches this file, so keep this copy in sync by hand when anything
# other than the version changes.
cask "vocamac-nightly" do
  version :latest
  sha256 :no_check

  url "https://github.com/VocaHQ/vocamac/releases/download/nightly/VocaMac-nightly-arm64.dmg",
      verified: "github.com/VocaHQ/vocamac/"
  name "VocaMac Nightly"
  desc "Nightly build of VocaMac — local voice-to-text dictation"
  homepage "https://vocamac.com/"

  conflicts_with cask: "vocamac"
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "VocaMac.app"

  zap trash: [
    "~/Library/Application Support/VocaMac",
    "~/Library/Caches/com.vocamac.app",
    "~/Library/Preferences/com.vocamac.app.plist",
    "~/Library/Saved Application State/com.vocamac.app.savedState",
  ]
end
