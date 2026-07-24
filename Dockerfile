FROM ruby:3.3.7-slim-bookworm

ARG FLUENTD_VERSION=1.18.0
ARG DATADOG_PLUGIN_VERSION=0.15.0

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
       build-essential \
       ca-certificates \
       curl \
       gosu \
    && gem install --no-document \
       "fluentd:${FLUENTD_VERSION}" \
       "fluent-plugin-datadog:${DATADOG_PLUGIN_VERSION}" \
    && apt-get purge --yes --auto-remove build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 1000 fluent \
    && useradd --system --uid 1000 --gid fluent --home-dir /fluentd fluent \
    && install -d -o fluent -g fluent \
       /fluentd/etc \
       /fluentd/buffer \
       /run/fluentd-certs

COPY fluent.conf /fluentd/etc/fluent.conf
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

EXPOSE 6514/tcp 24220/tcp

VOLUME ["/fluentd/buffer"]

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=4 \
  CMD curl --fail --silent http://127.0.0.1:24220/api/plugins.json >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["fluentd", "--config", "/fluentd/etc/fluent.conf", "--suppress-config-dump"]
