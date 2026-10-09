cask "vestal" do
  version "0.3.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/syntheit/vestal/releases/download/v#{version}/Vestal-#{version}.dmg"
  name "Vestal"
  desc "Keypress-toggled full-screen dashboard overlay"
  homepage "https://github.com/syntheit/vestal"

  depends_on macos: ">= :sonoma"

  app "Vestal.app"

  # A wrapper, not a symlink to the executable: macOS finds a process's bundle
  # (Info.plist, and the identity calendar and Automation access belong to)
  # from the path it was started by, which for a symlink is outside the app.
  preflight do
    File.write "#{staged_path}/vestal.wrapper.sh", <<~EOS
      #!/bin/sh
      exec '#{appdir}/Vestal.app/Contents/MacOS/vestal' "$@"
    EOS
    FileUtils.chmod "+x", "#{staged_path}/vestal.wrapper.sh"
  end
  binary "vestal.wrapper.sh", target: "vestal"

  zap trash: [
    "~/.config/vestal",
    "~/Library/Caches/Vestal",
    "~/Library/Logs/vestal.log",
  ]
end
