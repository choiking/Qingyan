#!/bin/bash
# Prints the path of a private keychain holding this Mac's local code-signing
# identity, creating it on first use. macOS ties microphone, screen-recording and
# accessibility grants to the app's designated requirement; an ad-hoc signature
# changes it on every build, a stable certificate keeps it. The key stays in the
# user's Application Support, outside the repository and the login keychain.
set -euo pipefail
NAME="Qingyan Local Signing"
DIR="$HOME/Library/Application Support/LocalInput/Signing"
KEYCHAIN="$DIR/signing.keychain-db"
PASSWORD_FILE="$DIR/keychain-password"
if test ! -f "$KEYCHAIN"; then
  umask 077
  mkdir -p "$DIR"
  chmod 700 "$DIR"
  /usr/bin/openssl rand -hex 24 > "$PASSWORD_FILE"
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  # LibreSSL's PKCS#12 defaults are the ones `security import` accepts.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  transfer=$(/usr/bin/openssl rand -hex 16)
  /usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/identity.p12" -passout "pass:$transfer"
  security create-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
  # No auto-lock; builds unlock it explicitly anyway.
  security set-keychain-settings "$KEYCHAIN"
  security import "$work/identity.p12" -k "$KEYCHAIN" -P "$transfer" -T /usr/bin/codesign >&2
  # Lets codesign use the key without a keychain prompt.
  security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" >/dev/null
  printf 'Created local signing identity: %s\n' "$KEYCHAIN" >&2
fi
security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
printf '%s\n' "$KEYCHAIN"
