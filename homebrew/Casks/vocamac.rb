# Mirror of the cask published in VocaHQ/homebrew-vocamac, which is what
# `brew install --cask vocamac` actually reads. `update-homebrew-cask.yml`
# rewrites `version` and `sha256` in THAT repo on every release publish and
# never touches this file, so keep this copy in sync by hand when anything
# other than the version changes.
cask "vocamac" do
  version "1.1.0"
  sha256 "82689e25049b70903e43e1b559c0531020aa777fbf6150b6525e1bb7529d3cb4"

  url "https://github.com/VocaHQ/vocamac/releases/download/v#{version}/VocaMac-#{version}-arm64.dmg"
  name "VocaMac"
  desc "Local voice-to-text dictation powered by WhisperKit"
  homepage "https://vocamac.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  conflicts_with cask: "vocamac-nightly"
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
