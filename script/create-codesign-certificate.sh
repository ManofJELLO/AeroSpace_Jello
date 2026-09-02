#!/usr/bin/env bash
# Create the self-signed code-signing identity that release.sh signs with.
#
# Why this exists: TCC (Privacy & Security) remembers Accessibility permission
# against the app's code signature. Ad-hoc signing ("-") has no stable identity,
# so TCC falls back to the binary hash, which changes on every build -- and
# AeroSpace loses Accessibility on every single upgrade. Signing with a stable
# certificate instead keeps one TCC entry valid across releases.
#
# Run once. Idempotent: exits successfully if the identity already exists.

cd "$(dirname "$0")/.."
set -euo pipefail

readonly IDENTITY="aerospace-codesign-certificate"
readonly KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

die() { echo "error: $*" > /dev/stderr; exit 1; }

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" > /dev/null 2>&1; then
    echo "'$IDENTITY' already exists in the login keychain. Nothing to do."
    exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "==> Generating a self-signed code-signing certificate"
# extendedKeyUsage=codeSigning is what makes codesign accept the identity, and
# basicConstraints/keyUsage are what make it a leaf rather than a CA.
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -keyout "$workdir/key.pem" -out "$workdir/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2> /dev/null

# A throwaway passphrase, not a secret: the bundle lives in a temp dir for the
# length of this script. It has to be non-empty because Security.framework
# rejects the MAC on an empty-password PKCS#12 written by LibreSSL.
p12_pass="$(uuidgen)"
openssl pkcs12 -export -out "$workdir/identity.p12" \
    -inkey "$workdir/key.pem" -in "$workdir/cert.pem" \
    -passout "pass:$p12_pass"

echo "==> Importing it into the login keychain"
# -T /usr/bin/codesign pre-authorizes codesign to use the private key, so that
# release.sh doesn't stop on a keychain prompt for every build.
security import "$workdir/identity.p12" -k "$KEYCHAIN" -P "$p12_pass" \
    -T /usr/bin/codesign -T /usr/bin/security > /dev/null

echo "==> Trusting it for code signing"
# This one opens a GUI prompt for the login password. There is no way around it:
# writing trust settings is deliberately gated behind user authentication.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$workdir/cert.pem"

# Let codesign use the key without prompting on every invocation.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "" "$KEYCHAIN" > /dev/null 2>&1 || true

security find-identity -v -p codesigning | grep "$IDENTITY" > /dev/null \
    || die "the identity was created but codesign doesn't consider it valid"

echo
echo "==> '$IDENTITY' is ready. release.sh will pick it up automatically."
