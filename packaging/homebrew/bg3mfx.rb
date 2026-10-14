# Homebrew formula for BG3 MetalFX. Copy to Formula/bg3mfx.rb in
# github.com/AndrewTriesToCode/homebrew-brews; tools/update-formula.sh fills
# in url and sha256 for each tagged release.
class Bg3mfx < Formula
  desc "MetalFX upscaling and frame generation for Baldur's Gate 3 on Steam"
  homepage "https://github.com/AndrewTriesToCode/bg3mfx"
  url "https://github.com/AndrewTriesToCode/bg3mfx/archive/refs/tags/v0.2.2.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  # Native hooks are ARM64-only; MetalFX frame interpolation needs macOS 26.
  depends_on arch: :arm64
  depends_on macos: :tahoe

  def install
    # Builds the player runtime and launcher locally: no download to quarantine,
    # and the linker signs both, so Gatekeeper never blocks them.
    system "make", "install", "PREFIX=#{prefix}", "VERSION=#{version}"
  end

  def caveats
    <<~EOS
      Start Baldur's Gate 3 (Steam version) with MetalFX:
        bg3mfx

      To add "BG3 MetalFX" to your Applications folder (and to Steam with
      Games > Add a Non-Steam Game to My Library):
        bg3mfx install-app

      Choose MetalFX options in the game under Options > Video.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/bg3mfx --version")
    assert_path_exists lib/"bg3mfx/libBG3MetalFX.dylib"
  end
end
