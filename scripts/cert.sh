#!/usr/bin/env bash
# Creates the "Local Self-Signed" code-signing identity in the login keychain if it's missing.
# TCC grants (Accessibility, Screen Recording) are pinned to it, so they survive rebuilds.
set -euo pipefail
NAME="Local Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\"" && exit 0

echo "🔑 Tworzę certyfikat \"$NAME\" (macOS zapyta o hasło, żeby mu zaufać)…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# /usr/bin/openssl is LibreSSL: its PKCS#12 output is what `security import` accepts (Homebrew OpenSSL 3 needs -legacy).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:temp
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
echo "✅ Certyfikat \"$NAME\" gotowy"
