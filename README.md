# Aiven logs to Datadog through Fluentd

This container accepts Aiven service logs as RFC 5424 syslog over TLS/TCP and
forwards them to the HTTPS log intake for the selected Datadog site. It bridges
this path:

```text
Aiven service -> TLS/TCP :6514 -> Fluentd -> HTTPS :443 -> Datadog
```

The Datadog API key is used only on the outbound HTTPS request. Do not include
it in the Aiven syslog template.

## Prerequisites

- A host reachable from Aiven on TCP port 6514, with a stable public DNS name
  or IP address
- Docker with Docker Compose
- A Datadog API key created in the destination Datadog organization
- A TLS certificate matching the relay's public DNS name or IP

Restrict inbound TCP/6514 to Aiven's outbound IP ranges for the region(s) used
by the database. Keep the Fluentd monitoring port bound to localhost.

## 1. Configure TLS

For a certificate issued by a public CA, place the full certificate chain and
unencrypted private key at:

```text
certs/server.crt
certs/server.key
```

For a private test deployment, create a dedicated CA and server certificate:

```sh
chmod +x scripts/generate-certs.sh
./scripts/generate-certs.sh logs.example.com
```

This also creates `certs/ca.crt`, which must be supplied as the CA when the
Aiven rsyslog endpoint is created. The generated private CA is suitable for a
controlled deployment; protect `certs/ca.key` and do not copy it to Aiven or
the relay host if it is not needed there. The CA includes critical
`CA:TRUE` and `keyCertSign,cRLSign` extensions required by Aiven's certificate
verifier. The server certificate is constrained to TLS server authentication.

The script refuses to overwrite existing certificate material. To rotate a
certificate, first move the existing `certs` files to a protected backup
directory, generate the replacement, and update Aiven with the new CA before
restarting the relay.

## 2. Start the relay

```sh
cp .env.example .env
```

Edit `.env`, set `DD_API_KEY`, and select the Datadog site with `DD_SITE`.
For example, use `us3.datadoghq.com` for US3 or `us5.datadoghq.com` for US5.
The API key must belong to an organization on that site.

Leave `DD_SERVICE` empty when this endpoint receives logs from multiple Aiven
services. The relay then uses each message's RFC 5424 hostname as its Datadog
`service`. Set `DD_SERVICE` only when all incoming logs should deliberately
share one static Datadog service name. Then run:

```sh
docker compose up --build -d
docker compose ps
docker compose logs -f fluentd
```

The buffer is stored in the `fluentd-buffer` Docker volume. Its default maximum
size is 1 GiB. When it fills, Fluentd applies backpressure and Aiven may retry
or eventually drop messages, so monitor disk usage and Fluentd errors.

## 3. Point Aiven at the relay

Create an RFC 5424 endpoint using TLS. With the Aiven CLI and the generated
private CA:

```sh
avn service integration-endpoint-create \
  --project YOUR_AIVEN_PROJECT \
  -d datadog-fluentd \
  -t rsyslog \
  -c server=logs.example.com \
  -c port=6514 \
  -c format=rfc5424 \
  -c tls=true \
  -c ca="$(cat certs/ca.crt)"
```

Alternatively, create the endpoint in the Aiven Console and paste the full PEM
contents of `certs/ca.crt` into the CA field. For a publicly trusted server
certificate, omit `ca`.

Find the endpoint ID and attach it to the database:

```sh
avn service integration-endpoint-list --project YOUR_AIVEN_PROJECT

avn service integration-create \
  --project YOUR_AIVEN_PROJECT \
  -t rsyslog \
  -s YOUR_AIVEN_SERVICE \
  -D YOUR_ENDPOINT_ID
```

The same endpoint can be attached to multiple services.

## 4. Verify the whole path

Check the local listener and health endpoint:

```sh
docker compose ps
curl --fail http://127.0.0.1:24220/api/plugins.json
```

Send an RFC 5424 test message through the TLS listener:

```sh
test_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

printf '<14>1 %s test.aiven relay - - - Aiven relay test\n' "$test_timestamp" |
  openssl s_client \
    -quiet \
    -no_ign_eof \
    -connect logs.example.com:6514 \
    -servername logs.example.com \
    -CAfile certs/ca.crt
```

In the selected Datadog site's Log Explorer, search for:

```text
service:test.aiven "Aiven relay test"
```

Keep the Log Explorer time range on **Last 15 minutes** only when the test uses
the current UTC timestamp above. Fluentd preserves the RFC 5424 event time, so
a hard-coded older timestamp places the event in that older Datadog time
window.

To test Datadog independently of the syslog input, submit one event directly
from inside the relay container. A successful intake returns HTTP `202`:

```sh
docker compose exec fluentd sh -lc '
  curl --silent --show-error \
    --output /tmp/datadog-response \
    --write-out "HTTP %{http_code}\n" \
    --request POST \
    --header "Content-Type: application/json" \
    --header "DD-API-KEY: ${DD_API_KEY}" \
    --data "[{\"message\":\"Direct relay intake test\",\"service\":\"aiven-relay-test\",\"ddsource\":\"aiven\"}]" \
    "https://http-intake.logs.${DD_SITE}/api/v2/logs"
  cat /tmp/datadog-response
'
```

Search for `service:aiven-relay-test "Direct relay intake test"`. An HTTP `403`
means the API key is invalid or belongs to a different Datadog site. DNS,
connection, or TLS errors indicate an outbound networking problem.

For Aiven-originated traffic, also check the integration status in the Aiven
Console and inspect relay output:

```sh
docker compose logs --since=15m fluentd
```

Successful startup includes a connection to the selected site's intake, such
as `https://http-intake.logs.us5.datadoghq.com:443` for US5. HTTP 403 normally
means the API key is invalid or belongs to another Datadog site. Connection
timeouts normally indicate outbound DNS/firewall restrictions.

## Operational notes

- TLS verification is enabled for outbound Datadog traffic.
- The generated private key remains mode `0600` on the host. The container
  entrypoint temporarily uses `DAC_READ_SEARCH` to read a host-owned bind mount
  and `CHOWN` to prepare the persistent buffer. `SETUID` and `SETGID` allow
  `gosu` to switch users. The entrypoint copies the certificate and key to a
  root-owned, group-protected runtime directory and then starts Fluentd as
  UID/GID 1000 with those capabilities cleared.
- `DD_SITE` accepts `datadoghq.com`, `us3.datadoghq.com`,
  `us5.datadoghq.com`, `datadoghq.eu`, `ap1.datadoghq.com`,
  `ap2.datadoghq.com`, `uk1.datadoghq.com`, `ddog-gov.com`, or
  `us2.ddog-gov.com`. It defaults to US3 for backward compatibility.
- The API key is read from the environment and Fluentd masks the plugin's
  `api_key` setting. Use a secret manager in production if the container
  platform supports one.
- The parsed RFC 5424 `host`, `ident`, `pid`, priority, and message are
  preserved. Datadog receives the original Aiven hostname rather than the
  relay container hostname.
- By default, the RFC 5424 hostname is copied to both Datadog's reserved
  `service` field and the `aiven_service` attribute. The RFC 5424 app-name is
  copied to `aiven_component`. This keeps logs from several attached Aiven
  services distinguishable. A non-empty `DD_SERVICE` overrides the dynamic
  service name for every event.
- If different Aiven projects contain identically named services, make the
  hostname unique by using a separate custom syslog endpoint per project and
  appending the project name to `%HOSTNAME%` in its RFC 5424-compatible
  template. Otherwise Datadog intentionally groups those identical hostnames
  under the same `service`.
- To trigger a Datadog database integration pipeline, set `DD_SOURCE` to the
  applicable technology (for example, `postgresql`) after confirming the
  expected pipeline in your Datadog organization.
