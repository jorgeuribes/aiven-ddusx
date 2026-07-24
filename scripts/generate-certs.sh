#!/bin/sh
set -eu

relay_name="${1:-}"
output_dir="${2:-certs}"

if [ -z "$relay_name" ]; then
  echo "Usage: $0 <relay-public-dns-or-ip> [output-directory]" >&2
  exit 2
fi

mkdir -p "$output_dir"
extension_file="$(mktemp)"
trap 'rm -f "$extension_file"' EXIT HUP INT TERM

case "$relay_name" in
  *[!0-9.]*)
    san="DNS:${relay_name}"
    ;;
  *)
    san="IP:${relay_name}"
    ;;
esac

{
  echo "subjectAltName=${san}"
  echo "extendedKeyUsage=serverAuth"
} >"$extension_file"

openssl genrsa -out "$output_dir/ca.key" 3072
openssl req -x509 -new -sha256 -days 3650 \
  -key "$output_dir/ca.key" \
  -subj "/CN=Aiven Fluentd Relay CA" \
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
  -extfile "$extension_file" \
  -out "$output_dir/server.crt"

chmod 0600 "$output_dir/ca.key" "$output_dir/server.key"
rm -f "$output_dir/server.csr" "$output_dir/ca.srl"

echo "Created relay certificate for ${relay_name} in ${output_dir}"
echo "Keep ca.key and server.key secret. Supply ca.crt to the Aiven endpoint."
