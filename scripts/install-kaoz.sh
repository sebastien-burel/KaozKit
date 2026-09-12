#!/usr/bin/env bash
#
# install-kaoz.sh — put `kaoz` on the PATH.
#
# After `swift build -c release`, the binary is .build/release/kaoz (on Apple
# Silicon that directory is an alias of .build/arm64-apple-macosx/release). This
# links it as /usr/local/bin/kaoz so it can be typed from anywhere.
#
# A symlink, deliberately not a copy: the runtime's JavaScript resources
# (KaozKit_KaozKit.bundle/js/…) and the MLX Metal library live next to the
# binary, and a copy moved elsewhere no longer finds them. The flip side is
# that `rm -rf .build` breaks the link — run this again after a clean build.
#
# Without sudo, the PATH works just as well:
#   export PATH="$PWD/.build/release:$PATH"
set -euo pipefail

cd "$(dirname "$0")/.."
binary="$PWD/.build/release/kaoz"
target=/usr/local/bin/kaoz

if [ ! -x "$binary" ]; then
    echo "error: $binary not found — run 'swift build -c release' first" >&2
    exit 1
fi

link() { ln -sfn "$binary" "$target"; }
if [ -w "$(dirname "$target")" ]; then
    link
else
    echo "linking $target needs sudo (the directory is not writable)"
    sudo ln -sfn "$binary" "$target"
fi

echo "linked $target -> $binary"
"$target" --version
