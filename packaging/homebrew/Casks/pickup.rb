cask "pickup" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/macx/pickup/releases/download/v#{version}/Pickup-#{version}.dmg"
  name "Pickup"
  name "Pickup for Mac"
  desc "Answer and place Android phone calls from the menu bar"
  homepage "https://github.com/macx/pickup"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Pickup.app"

  zap trash: [
    "~/Library/Application Support/Pickup",
    "~/Library/Containers/dev.eiken.pickup",
    "~/Library/Logs/Pickup",
    "~/Library/Preferences/dev.eiken.pickup.plist",
  ]
end
