#!/usr/bin/env bash
# Create a stable, self-signed code-signing certificate in the login Keychain.
#
# Why: the app reads another app's Keychain item (Claude Code-credentials) via
# SecItemCopyMatching. macOS gates that item with an ACL keyed on the *reader's*
# code-signing identity. An unsigned / ad-hoc-signed app has a different identity on
# every build, so "Always Allow" never sticks — you get re-prompted after each rebuild.
#
# Signing every build with the SAME self-signed cert gives the app one stable
# "designated requirement", so a single "Always Allow" persists across all rebuilds.
# No Apple Developer account required.
#
# This is idempotent: run it once. If the identity already exists it does nothing.
#
# Usage: scripts/make-signing-cert.sh
set -euo pipefail

CERT_CN="Claude Usage Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "OK  Signing identity \"$CERT_CN\" already exists — nothing to do."
    exit 0
fi

echo ">> Generating self-signed code-signing certificate \"$CERT_CN\" ..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# OpenSSL config: self-signed leaf, codeSigning extended key usage.
cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CERT_CN
[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# Bundle key + cert into a PKCS#12 for import. Use a throwaway passphrase: Apple's
# `security import` is unreliable with empty-passphrase p12 files ("MAC verification
# failed"). The p12 is deleted on exit, so the passphrase value is irrelevant.
# -legacy + SHA1 PBE: OpenSSL 3 defaults to AES-256/SHA-256 PKCS#12 MAC, which Apple's
# Security framework cannot read. Force the legacy 3DES/SHA1 scheme macOS understands.
P12PASS="transient"
openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -name "$CERT_CN" -out "$TMP/identity.p12" -passout "pass:$P12PASS" >/dev/null 2>&1

echo ">> Importing into login Keychain ..."
# -T /usr/bin/codesign: let codesign use the private key without prompting.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign >/dev/null

# No trust step needed: codesign signs fine with an untrusted self-signed cert, and
# the Keychain ACL matches on the certificate *hash* (the signature's "designated
# requirement"), not on system trust. Skipping it avoids a GUI auth prompt.
echo ""
echo "OK  Created signing identity \"$CERT_CN\"."
echo ""
echo "Next: rebuild with scripts/make-app.sh — it will sign with this identity."
echo "Then launch the app once and click \"Always Allow\" on the Keychain prompt."
echo "That allow now persists across every future rebuild."
