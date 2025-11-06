class Floo < Formula
  desc "Secure, high-performance tunneling in Zig. Expose your home services or access remote ones"
  homepage "https://github.com/YUX/floo"
  version "0.1.2"
  license "MIT"

  if Hardware::CPU.arm?
    url "https://github.com/YUX/floo/releases/download/v0.1.2/floo-aarch64-macos-m1.tar.gz"
    sha256 "TO_BE_CALCULATED" # Update this after release
  else
    url "https://github.com/YUX/floo/releases/download/v0.1.2/floo-x86_64-macos-haswell.tar.gz"
    sha256 "TO_BE_CALCULATED" # Update this after release
  end

  def install
    bin.install "flooc"
    bin.install "floos"
    doc.install "README.md"
    (pkgshare/"examples").install "flooc.toml.example"
    (pkgshare/"examples").install "floos.toml.example"
  end

  def caveats
    <<~EOS
      Example configuration files are installed to:
        #{pkgshare}/examples/

      To get started:
        1. Copy example configs: cp #{pkgshare}/examples/*.toml.example .
        2. Edit configs with your settings
        3. Run: flooc flooc.toml (client) or floos floos.toml (server)

      See https://github.com/YUX/floo for complete documentation.
    EOS
  end

  test do
    system "#{bin}/flooc", "--version"
    system "#{bin}/floos", "--version"
  end
end
