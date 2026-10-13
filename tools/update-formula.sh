#!/bin/sh
# Point the Homebrew formula at a tagged release.
#   tools/update-formula.sh 0.2.0 ../homebrew-brews/Formula/bg3mfx.rb
# Run after pushing tag v<version>; then commit and push the tap.
set -eu
version="${1:?usage: update-formula.sh <version> <formula.rb>}"
formula="${2:?usage: update-formula.sh <version> <formula.rb>}"
url="https://github.com/AndrewTriesToCode/bg3mfx/archive/refs/tags/v${version}.tar.gz"
sha=$(curl -fsSL "$url" | shasum -a 256 | cut -d' ' -f1)
sed -i '' -E \
    -e "s|^(  url )\".*\"|\\1\"${url}\"|" \
    -e "s|^(  sha256 )\".*\"|\\1\"${sha}\"|" \
    "$formula"
echo "Updated $formula to v${version} (sha256 ${sha})"
