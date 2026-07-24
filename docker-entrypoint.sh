#!/bin/sh
set -eu

: "${DD_API_KEY:?DD_API_KEY must be set}"

dd_site="${DD_SITE:-us3.datadoghq.com}"
case "$dd_site" in
  datadoghq.com|us3.datadoghq.com|us5.datadoghq.com|datadoghq.eu|ap1.datadoghq.com|ap2.datadoghq.com|uk1.datadoghq.com|ddog-gov.com|us2.ddog-gov.com)
    ;;
  *)
    echo "Unsupported DD_SITE: $dd_site" >&2
    echo "Use datadoghq.com, us3.datadoghq.com, us5.datadoghq.com, datadoghq.eu, ap1.datadoghq.com, ap2.datadoghq.com, uk1.datadoghq.com, ddog-gov.com, or us2.ddog-gov.com." >&2
    exit 1
    ;;
esac

cert_source="${TLS_CERT_PATH:-/fluentd/certs/server.crt}"
key_source="${TLS_KEY_PATH:-/fluentd/certs/server.key}"

if [ ! -r "$cert_source" ]; then
  echo "TLS certificate is not readable: $cert_source" >&2
  exit 1
fi

if [ ! -r "$key_source" ]; then
  echo "TLS private key is not readable: $key_source" >&2
  exit 1
fi

install -d -o fluent -g fluent /run/fluentd-certs /fluentd/buffer
install -o fluent -g fluent -m 0444 "$cert_source" /run/fluentd-certs/server.crt
install -o fluent -g fluent -m 0400 "$key_source" /run/fluentd-certs/server.key
chown fluent:fluent /fluentd/buffer

exec gosu fluent "$@"
