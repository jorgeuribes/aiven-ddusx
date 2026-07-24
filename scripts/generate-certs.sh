#!/bin/sh
set -eu

relay_name="${1:-}"
output_dir="${2:-certs}"

if [ -z "$relay_name" ]; then
  echo "Usage: $0 <relay-public-dns-or-ip> [output-directory]" >&2
  exit 2
fi

mkdir -p "$output_dir"

for existing_file in ca.key ca.crt server.key server.crt; do
  if [ -e "$output_dir/$existing_file" ]; then
    echo "Refusing to overwrite existing certificate material: $output_dir/$existing_file" >&2
    echo "Move the existing files to a backup directory before generating a replacement." >&2
    exit 1
  fi
done

ca_config="$(mktemp)"
server_extension_file="$(mktemp)"

cleanup() {
  rm -f "$ca_config" "$server_extension_file"
}
trap cleanup EXIT HUP INT TERM

case "$relay_name" in
  *[!0-9.]*)
    san="DNS:${relay_name}"
    ;;
  *)
    san="IP:${relay_name}"
    ;;
esac

{
  echo "basicConstraints=critical,CA:FALSE"
  echo "keyUsage=critical,digitalSignature,keyEncipherment"
  echo "subjectAltName=${san}"
  echo "extendedKeyUsage=serverAuth"
  echo "subjectKeyIdentifier=hash"
  echo "authorityKeyIdentifier=keyid,issuer"
} >"$server_extension_file"

cat >"$ca_config" <<'EOF'
[req]
distinguished_name = ca_subject
prompt = no
x509_extensions = ca_extensions

[ca_subject]
CN = Aiven Fluentd Relay CA

[ca_extensions]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl genrsa -out "$output_dir/ca.key" 3072
openssl req -x509 -new -sha256 -days 3650 \
  -key "$output_dir/ca.key" \
  -config "$ca_config" \
  -out "$output_dir/ca.crt"

openssl genrsa -out "$output_dir/server.key" 3072
openssl req -new -sha256 \
  -key "$output_dir/server.key" \
  -subj "/CN=${relay_name}" \
  -out "$output_dir/server.csr"

openssl x509 -req -sha256 -days 825 \
  -in "$output_dir/server.csr" \
  -CA "$output_dir/ca.crt" \
  -CAkey "$output_dir/ca.key" \
  -CAcreateserial \
  -extfile "$server_extension_file" \
  -out "$output_dir/server.crt"

chmod 0600 "$output_dir/ca.key" "$output_dir/server.key"
rm -f "$output_dir/server.csr" "$output_dir/ca.srl"

case "$san" in
  IP:*)
    openssl verify -purpose sslserver -verify_ip "$relay_name" \
      -CAfile "$output_dir/ca.crt" "$output_dir/server.crt"
    ;;
  DNS:*)
    openssl verify -purpose sslserver -verify_hostname "$relay_name" \
      -CAfile "$output_dir/ca.crt" "$output_dir/server.crt"
    ;;
esac

echo "Created relay certificate for ${relay_name} in ${output_dir}"
echo "Keep ca.key and server.key secret. Supply ca.crt to the Aiven endpoint."
