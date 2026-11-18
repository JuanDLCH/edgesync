#!/bin/sh
# Optional: creates a self-signed code-signing certificate "EdgeSync Local" in the login keychain,
# so the Accessibility grant survives rebuilds (ad-hoc signatures change on every build).
# It is only usable for code signing, is not trusted for anything else, and never leaves the Mac.
set -e
if security find-certificate -c "EdgeSync Local" >/dev/null 2>&1; then echo "Already exists."; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/cfg" <<'C'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = EdgeSync Local
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
C
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/cfg" 2>/dev/null
P=$(openssl rand -hex 12)
# -legacy: macOS' keychain can't read the PKCS#12 algorithms newer OpenSSL uses by default
openssl pkcs12 -export -legacy -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "pass:$P" -name "EdgeSync Local" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "pass:$P" -name "EdgeSync Local"
security import "$T/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$P" -T /usr/bin/codesign
echo "Created. Rebuild with ./build.sh, then grant Accessibility once more."
