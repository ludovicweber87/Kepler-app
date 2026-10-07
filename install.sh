#!/bin/sh
# Kepler installer — macOS, Apple Silicon. Downloads the latest Kepler.app from
# the public releases and installs it in /Applications (or ~/Applications).
# Re-runnable: installs the latest version in place.
#
#   curl -fsSL https://raw.githubusercontent.com/ludovicweber87/Kepler-app/main/install.sh | sh
#
# L'app n'est pas signée par un Developer ID. Téléchargée par curl, elle ne
# reçoit pas d'attribut de quarantaine : Gatekeeper ne bloque pas son lancement,
# contrairement à un .dmg récupéré depuis un navigateur.
#
# Contributeurs : pour un checkout de dev avec la commande `kepler`, voir
# scripts/install-dev.sh.
set -eu

RELEASES="https://github.com/ludovicweber87/Kepler-app/releases"
APP_NAME="Kepler.app"

fail() {
	echo "✗ $*" >&2
	exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "Kepler runs on macOS only."
[ "$(uname -m)" = "arm64" ] || fail "Kepler requires an Apple Silicon Mac (M1 or later)."

if [ -w /Applications ]; then
	DEST="/Applications"
else
	DEST="$HOME/Applications"
	mkdir -p "$DEST"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Fetching the latest release..."
curl -fsSL "$RELEASES/latest/download/latest-mac.yml" -o "$WORK/latest-mac.yml" ||
	fail "Could not reach $RELEASES."

# Écrit par electron-builder : `  - url: <zip>` suivi de `    sha512: <base64>`.
ZIP_NAME="$(awk '/^  - url: .*\.zip$/ {print $3; exit}' "$WORK/latest-mac.yml")"
ZIP_SHA="$(awk -v z="$ZIP_NAME" '$3 == z {getline; print $2; exit}' "$WORK/latest-mac.yml")"
VERSION="$(awk '/^version:/ {print $2; exit}' "$WORK/latest-mac.yml" | tr -d "'\"")"
[ -n "$ZIP_NAME" ] && [ -n "$ZIP_SHA" ] && [ -n "$VERSION" ] || fail "The latest release is incomplete."

echo "→ Downloading Kepler $VERSION..."
curl -fL --progress-bar "$RELEASES/download/v$VERSION/$ZIP_NAME" -o "$WORK/kepler.zip" ||
	fail "Download failed."

ACTUAL_SHA="$(shasum -a 512 "$WORK/kepler.zip" | awk '{print $1}' | xxd -r -p | base64)"
[ "$ACTUAL_SHA" = "$ZIP_SHA" ] || fail "Checksum mismatch: the download is corrupted."

# `ditto` préserve liens symboliques et signatures, contrairement à `unzip`.
ditto -x -k "$WORK/kepler.zip" "$WORK/extracted"
[ -d "$WORK/extracted/$APP_NAME" ] || fail "The archive does not contain $APP_NAME."

if pgrep -f "$DEST/$APP_NAME/Contents/MacOS/" >/dev/null 2>&1; then
	echo "→ Quitting the running Kepler..."
	osascript -e 'quit app "Kepler"' >/dev/null 2>&1 || true
	sleep 2
fi

rm -rf "$DEST/$APP_NAME"
mv "$WORK/extracted/$APP_NAME" "$DEST/$APP_NAME"
echo "✓ Kepler $VERSION installed in $DEST."

# Kepler bloque au démarrage sans gh ; claude, tmux et git servent aux agents.
missing=""
for bin in gh claude tmux git; do
	command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
done
if [ -n "$missing" ]; then
	echo ""
	echo "  Missing tools:$missing"
	echo "    gh      → brew install gh && gh auth login -s \"repo,read:org,project\""
	echo "    claude  → https://docs.claude.com/en/docs/claude-code"
	echo "    tmux    → brew install tmux"
	echo "    git     → xcode-select --install"
fi

open "$DEST/$APP_NAME"
