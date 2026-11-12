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
# Authenticité : le manifeste de la release (`latest-*.yml`, qui donne le sha512
# du fichier à installer) n'est utilisé qu'après vérification de sa signature
# ed25519 (`latest-*.yml.sig`) avec la clé publique ci-dessous — la même que
# celle embarquée dans l'app (packages/desktop/src/updateKey.js).
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

# --- Signature des releases (testé par scripts/install-signature.test.mjs) ---

# Clé publique ed25519 des releases (SPKI, PEM).
UPDATE_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAThvbKUgHubxnBXKMN4DgabWwcmma8H4M30KaRhwP4wA=
-----END PUBLIC KEY-----'

# Un openssl qui connaît ed25519 : celui d'Ubuntu (OpenSSL ≥ 1.1.1), ou celui de
# Homebrew sur un Mac. Le LibreSSL livré avec macOS (/usr/bin/openssl) ne sait pas
# lire une clé ed25519 : il est écarté par le test `pkey`.
ed25519_openssl() {
	for bin in openssl /opt/homebrew/bin/openssl /usr/local/bin/openssl \
		/opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
		command -v "$bin" >/dev/null 2>&1 || continue
		if "$bin" pkey -pubin -in "$1" -noout >/dev/null 2>&1; then
			echo "$bin"
			return 0
		fi
	done
	return 1
}

# Repli sans openssl ed25519 (Mac sans Homebrew) : vérification ed25519 en Perl
# pur (RFC 8032, §5.1.7), avec les modules de base livrés par macOS et Ubuntu
# (Math::BigInt, Digest::SHA, MIME::Base64). Arguments : clé PEM, fichier, signature base64.
write_ed25519_perl() {
	cat >"$1" <<'PERL'
use strict;
use warnings;
use Math::BigInt;
use Digest::SHA qw(sha512);
use MIME::Base64 qw(decode_base64);

sub slurp { open(my $f, '<:raw', $_[0]) or exit 1; local $/; my $d = <$f>; close $f; return defined $d ? $d : ''; }
my ($key_file, $msg_file, $sig_file) = @ARGV;

my $p = Math::BigInt->new(2)->bpow(255)->bsub(19);
my $q = Math::BigInt->new(2)->bpow(252)->badd(Math::BigInt->new('27742317777372353535851937790883648493'));
sub md { my $x = $_[0]->copy; $x->bmod($p); return $x }
sub inv { my $x = $_[0]->copy; $x->bmodpow($p - 2, $p); return $x }
my $d = md(Math::BigInt->new(-121665) * inv(Math::BigInt->new(121666)));
my $sqrt_m1 = Math::BigInt->new(2)->bmodpow(($p - 1) / 4, $p);

# Entier little-endian (RFC 8032) depuis des octets.
sub le_int { return Math::BigInt->from_hex('0x' . unpack('H*', scalar reverse $_[0])) }

sub point_add {
	my ($P, $Q) = @_;
	my $A = md(($P->[1] - $P->[0]) * ($Q->[1] - $Q->[0]));
	my $B = md(($P->[1] + $P->[0]) * ($Q->[1] + $Q->[0]));
	my $C = md($P->[3] * $Q->[3] * $d * 2);
	my $D = md($P->[2] * $Q->[2] * 2);
	my ($E, $F, $G, $H) = ($B - $A, $D - $C, $D + $C, $B + $A);
	return [md($E * $F), md($G * $H), md($F * $G), md($E * $H)];
}
sub point_mul {
	my ($s, $P) = @_;
	my $Q = [Math::BigInt->new(0), Math::BigInt->new(1), Math::BigInt->new(1), Math::BigInt->new(0)];
	for my $bit (reverse split //, substr($s->as_bin, 2)) {
		$Q = point_add($Q, $P) if $bit eq '1';
		$P = point_add($P, $P);
	}
	return $Q;
}
sub point_equal {
	my ($P, $Q) = @_;
	return md($P->[0] * $Q->[2] - $Q->[0] * $P->[2])->is_zero
		&& md($P->[1] * $Q->[2] - $Q->[1] * $P->[2])->is_zero;
}
sub recover_x {
	my ($y, $sign) = @_;
	return undef if $y >= $p;
	my $x2 = md(($y * $y - 1) * inv(md($d * $y * $y + 1)));
	return $sign ? undef : Math::BigInt->new(0) if $x2->is_zero;
	my $x = $x2->copy->bmodpow(($p + 3) / 8, $p);
	$x = md($x * $sqrt_m1) unless md($x * $x - $x2)->is_zero;
	return undef unless md($x * $x - $x2)->is_zero;
	$x = $p - $x if ($x->is_odd ? 1 : 0) != $sign;
	return $x;
}
sub point_decompress {
	my $s = shift;
	return undef unless length($s) == 32;
	my $y = le_int($s);
	my $sign = $y >= Math::BigInt->new(2)->bpow(255) ? 1 : 0;
	$y = $y - Math::BigInt->new(2)->bpow(255) if $sign;
	my $x = recover_x($y, $sign);
	return undef unless defined $x;
	return [$x, $y, Math::BigInt->new(1), md($x * $y)];
}

my $g_y = md(Math::BigInt->new(4) * inv(Math::BigInt->new(5)));
my $g_x = recover_x($g_y, 0);
my $G = [$g_x, $g_y, Math::BigInt->new(1), md($g_x * $g_y)];

# Clé SPKI ed25519 : préfixe DER fixe (12 octets) puis les 32 octets de la clé.
my $pem = slurp($key_file);
$pem =~ s/-----[A-Z ]+-----//g;
my $der = decode_base64($pem);
exit 1 unless length($der) == 44 && unpack('H24', $der) eq '302a300506032b6570032100';
my $public = substr($der, 12);

my $sig_text = slurp($sig_file);
$sig_text =~ s/\s+//g;
exit 1 unless $sig_text =~ m{^[A-Za-z0-9+/]+={0,2}$};
my $sig = decode_base64($sig_text);
exit 1 unless length($sig) == 64;
my $msg = slurp($msg_file);

my $A = point_decompress($public) or exit 1;
my $Rs = substr($sig, 0, 32);
my $R = point_decompress($Rs) or exit 1;
my $s = le_int(substr($sig, 32));
exit 1 unless $s < $q;
my $h = le_int(sha512($Rs . $public . $msg));
$h->bmod($q);
exit(point_equal(point_mul($s, $G), point_add($R, point_mul($h, $A))) ? 0 : 1);
PERL
}

# verify_signature <fichier> <signature base64> : 0 si la signature est valide
# pour UPDATE_PUBLIC_KEY. KEPLER_VERIFY_BACKEND=perl force le repli Perl (tests) ;
# rien ne permet de sauter la vérification.
verify_signature() {
	printf '%s\n' "$UPDATE_PUBLIC_KEY" >"$WORK/update-key.pem"
	if [ "${KEPLER_VERIFY_BACKEND:-}" != perl ] && bin="$(ed25519_openssl "$WORK/update-key.pem")"; then
		tr -d ' \n\r' <"$2" | "$bin" base64 -d -A -out "$WORK/signature.bin" 2>/dev/null || return 1
		"$bin" pkeyutl -verify -pubin -inkey "$WORK/update-key.pem" -rawin \
			-in "$1" -sigfile "$WORK/signature.bin" 2>/dev/null | grep -q 'Signature Verified Successfully'
		return
	fi
	command -v perl >/dev/null 2>&1 || fail "Cannot verify the release signature: install openssl (or perl)."
	write_ed25519_perl "$WORK/ed25519.pl"
	perl "$WORK/ed25519.pl" "$WORK/update-key.pem" "$1" "$2"
}

# fetch_manifest <nom> : télécharge le manifeste de la dernière release et sa
# signature, et s'arrête si la signature n'est pas valide.
fetch_manifest() {
	curl -fsSL "$RELEASES/latest/download/$1" -o "$WORK/$1" ||
		fail "Could not reach $RELEASES."
	signed_version="$(manifest_version "$WORK/$1")"
	[ -n "$signed_version" ] || fail "The latest release is incomplete."
	curl -fsSL "$RELEASES/download/v$signed_version/$1.sig" -o "$WORK/$1.sig" ||
		fail "The latest release is not signed: installation refused."
	verify_signature "$WORK/$1" "$WORK/$1.sig" ||
		fail "The release signature is invalid: installation refused."
	echo "→ Release signature verified."
}

# --- fin signature ---

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
	fetch_manifest latest-linux.yml
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
fetch_manifest latest-mac.yml

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
