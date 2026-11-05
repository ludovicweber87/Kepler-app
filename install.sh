#!/bin/sh
# Kepler installer — macOS (Apple Silicon) and Ubuntu (x64). Downloads the latest
# Kepler from the public releases and installs it: Kepler.app in /Applications
# (or ~/Applications) on a Mac, the .deb package through apt on Ubuntu.
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

# sha512 en base64, le format des manifestes d'electron-builder.
sha512_base64() {
	openssl dgst -sha512 -binary "$1" | base64 | tr -d '\n'
}

# Champs du manifeste écrit par electron-builder (ou par build-app.mjs sous
# Linux) : `  - url: <fichier>` suivi de `    sha512: <base64>`.
manifest_url() { awk -v ext="$2" '/^  - url: / && $3 ~ ext"$" {print $3; exit}' "$1"; }
manifest_sha() { awk -v f="$2" '$3 == f {getline; print $2; exit}' "$1"; }
manifest_version() { awk '/^version:/ {print $2; exit}' "$1" | tr -d "'\""; }

# Outils dont Kepler a besoin : gh bloque le démarrage ; claude, tmux et git servent aux agents.
check_tools() {
	missing=""
	for bin in gh claude tmux git; do
		command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
	done
	[ -z "$missing" ] && return 0
	echo ""
	echo "  Missing tools:$missing"
	if [ "$1" = linux ]; then
		echo "    gh, tmux, git → sudo apt install gh tmux git && gh auth login -s \"repo,read:org,project\""
	else
		echo "    gh      → brew install gh && gh auth login -s \"repo,read:org,project\""
		echo "    tmux    → brew install tmux"
		echo "    git     → xcode-select --install"
	fi
	echo "    claude  → https://docs.claude.com/en/docs/claude-code"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

install_linux() {
	[ "$(uname -m)" = "x86_64" ] || fail "On Linux, Kepler requires an x64 PC."
	command -v apt-get >/dev/null 2>&1 || fail "On Linux, Kepler installs on Ubuntu (or Debian) only."

	echo "→ Fetching the latest release..."
	curl -fsSL "$RELEASES/latest/download/latest-linux.yml" -o "$WORK/latest-linux.yml" ||
		fail "Could not reach $RELEASES."
	DEB_NAME="$(manifest_url "$WORK/latest-linux.yml" '\\.deb')"
	DEB_SHA="$(manifest_sha "$WORK/latest-linux.yml" "$DEB_NAME")"
	VERSION="$(manifest_version "$WORK/latest-linux.yml")"
	[ -n "$DEB_NAME" ] && [ -n "$DEB_SHA" ] && [ -n "$VERSION" ] || fail "The latest release is incomplete."

	echo "→ Downloading Kepler $VERSION..."
	curl -fL --progress-bar "$RELEASES/download/v$VERSION/$DEB_NAME" -o "$WORK/kepler.deb" ||
		fail "Download failed."
	[ "$(sha512_base64 "$WORK/kepler.deb")" = "$DEB_SHA" ] || fail "Checksum mismatch: the download is corrupted."

	# apt résout les dépendances du paquet ; `_apt` doit pouvoir lire le fichier.
	chmod 755 "$WORK" && chmod 644 "$WORK/kepler.deb"
	echo "→ Installing (your password may be asked)..."
	sudo apt-get install -y "$WORK/kepler.deb" || fail "apt could not install Kepler."
	echo "✓ Kepler $VERSION installed. Open it from your applications."

	check_tools linux
}

case "$(uname -s)" in
Darwin) ;;
Linux)
	install_linux
	exit 0
	;;
*) fail "Kepler runs on macOS and Ubuntu only." ;;
esac

[ "$(uname -m)" = "arm64" ] || fail "Kepler requires an Apple Silicon Mac (M1 or later)."

if [ -w /Applications ]; then
	DEST="/Applications"
else
	DEST="$HOME/Applications"
	mkdir -p "$DEST"
fi

echo "→ Fetching the latest release..."
curl -fsSL "$RELEASES/latest/download/latest-mac.yml" -o "$WORK/latest-mac.yml" ||
	fail "Could not reach $RELEASES."

ZIP_NAME="$(manifest_url "$WORK/latest-mac.yml" '\\.zip')"
ZIP_SHA="$(manifest_sha "$WORK/latest-mac.yml" "$ZIP_NAME")"
VERSION="$(manifest_version "$WORK/latest-mac.yml")"
[ -n "$ZIP_NAME" ] && [ -n "$ZIP_SHA" ] && [ -n "$VERSION" ] || fail "The latest release is incomplete."

echo "→ Downloading Kepler $VERSION..."
curl -fL --progress-bar "$RELEASES/download/v$VERSION/$ZIP_NAME" -o "$WORK/kepler.zip" ||
	fail "Download failed."

[ "$(sha512_base64 "$WORK/kepler.zip")" = "$ZIP_SHA" ] || fail "Checksum mismatch: the download is corrupted."

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

check_tools mac

open "$DEST/$APP_NAME"
