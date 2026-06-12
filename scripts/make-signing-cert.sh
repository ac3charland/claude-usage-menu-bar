#!/usr/bin/env bash
# Create a stable, *trusted* self-signed code-signing certificate in the login Keychain.
#
# Why: the app reads another app's Keychain item (Claude Code-credentials) via
# SecItemCopyMatching. macOS gates that item with an ACL keyed on the *reader's*
# code-signing identity. An unsigned / ad-hoc-signed app has a different identity on
# every build, so "Always Allow" never sticks — you get re-prompted after each rebuild.
#
# Signing every build with the SAME self-signed cert gives the app one stable
# "designated requirement". But that is NOT enough on its own: if the signing cert is
# untrusted, the Keychain authorization layer cannot *verify the app's authenticity*, so
# it shows the stronger "The authenticity of <app> cannot be verified" prompt and refuses
# to durably honor "Always Allow" — you get re-prompted for your login password roughly
# every token-refresh cycle. So we ALSO mark the cert as trusted for code signing.
# No Apple Developer account required.
#
# Idempotent: re-running ensures both the cert and its code-signing trust exist. Adding
# trust pops a one-time GUI auth prompt (you confirm with your login password); that one
# prompt is the whole point — it's what stops the recurring ones.
#
# Usage: scripts/make-signing-cert.sh
set -euo pipefail

CERT_CN="Claude Usage Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

ensure_trust() {
    # Trust the (self-signed → root) cert specifically for the code-signing policy, in the
    # user's login keychain. Honored for the current user without sudo. Skip if already set
    # so re-runs don't re-prompt for the keychain password.
    if security dump-trust-settings 2>/dev/null | grep -qi "$CERT_CN"; then
        echo "OK  \"$CERT_CN\" is already trusted for code signing — nothing to do."
        return 0
    fi
    echo ">> Marking \"$CERT_CN\" as trusted for code signing (one-time auth prompt) ..."
    local pem; pem="$(mktemp)"; trap 'rm -f "$pem"' RETURN
    security find-certificate -c "$CERT_CN" -p "$KEYCHAIN" > "$pem"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$pem"
    echo "OK  Trust settings updated."
}

if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "OK  Signing identity \"$CERT_CN\" already exists."
    ensure_trust
    echo ""
    echo "Next: rebuild with scripts/make-app.sh and launch once; \"Always Allow\" now sticks."
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

# codesign signs fine with an untrusted self-signed cert, BUT the Keychain
# authorization layer additionally validates the *authenticity* of the requesting app
# against trusted code-signing certs. An untrusted cert fails that check and triggers a
# recurring "authenticity cannot be verified" password prompt — so we trust it now.
echo ""
echo "OK  Created signing identity \"$CERT_CN\"."
ensure_trust
echo ""
echo "Next: rebuild with scripts/make-app.sh — it will sign with this identity."
echo "Then launch the app once and click \"Always Allow\" on the Keychain prompt."
echo "That allow now persists across every future rebuild."
