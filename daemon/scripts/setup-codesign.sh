#!/usr/bin/env bash
# One-time setup: generate a self-signed code-signing certificate in the user's
# login keychain so macOS TCC keys Screen Recording permission to a stable
# identity (the cert's Designated Requirement) instead of the per-build cdhash.
#
# Without this, every rebuild changes the binary fingerprint and silently
# invalidates the TCC grant. With this, every rebuild uses the same cert
# identity, and the TCC grant persists.
#
# Idempotent — safe to re-run. Skips if the identity already exists.
set -euo pipefail

CERT_NAME="${VALUEGUARD_CERT_NAME:-ValueGuard Developer}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

# If we already have a matching code-signing identity, do nothing.
if security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "Code-signing identity \"$CERT_NAME\" already exists in the login keychain."
    security find-identity -p codesigning -v "$KEYCHAIN" | grep "$CERT_NAME"
    exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

# OpenSSL config — minimum needed to mark this as a code-signing cert.
cat > cert.conf <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_req
[req_dn]
CN = $CERT_NAME
[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# Generate a self-signed RSA cert with codeSigning extended key usage.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout key.pem -out cert.pem \
    -days 3650 \
    -config cert.conf >/dev/null 2>&1

# Bundle key + cert into a PKCS#12 file. macOS `security import` with an
# empty passphrase is flaky on some OpenSSL versions; use a throwaway one.
P12_PASS="$(uuidgen)"
openssl pkcs12 -export -legacy \
    -inkey key.pem -in cert.pem \
    -name "$CERT_NAME" \
    -out cert.p12 \
    -passout "pass:$P12_PASS"

# Import into the login keychain. -A lets all apps use the key (simplest for
# development) — codesign needs read access. May prompt for keychain unlock.
security import cert.p12 \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -A \
    -t cert \
    -f pkcs12

echo ""
echo "Imported code-signing identity: $CERT_NAME"
echo ""
security find-identity -p codesigning -v "$KEYCHAIN" | grep "$CERT_NAME" || true

cat <<NEXT

Next step:
  Re-run daemon/scripts/bundle.sh — it will now sign with this identity.
  TCC's previous grant for the ad-hoc-signed bundle is invalid; you'll need
  to grant once more after this rebuild, but that grant will then persist
  across all future rebuilds because the cert identity is stable.
NEXT
