#!/usr/bin/env bash
# One-time: create a local self-signed code signing identity, "Hisashi Dev".
# A stable signature keeps macOS permissions (Accessibility) across rebuilds.
set -euo pipefail
name="Hisashi Dev"
if security find-certificate -c "$name" >/dev/null 2>&1; then
  echo "$name already exists"; exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -passout pass:hisashi -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" 2>/dev/null \
  || openssl pkcs12 -export -passout pass:hisashi -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12"
security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P hisashi -T /usr/bin/codesign
echo "created $name"
