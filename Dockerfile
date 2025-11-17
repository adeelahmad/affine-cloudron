ARG AFFINE_VERSION=0.25.5
FROM ghcr.io/toeverything/affine:${AFFINE_VERSION} AS upstream

FROM cloudron/base:5.0.0

ENV APP_CODE_DIR=/app/code \
    APP_DATA_DIR=/app/data \
    APP_RUNTIME_DIR=/run/affine \
    APP_TMP_DIR=/tmp/data \
    APP_BUILD_DIR=/app/code/affine \
    NODE_ENV=production \
    PORT=3010 \
    LD_PRELOAD=libjemalloc.so.2

RUN mkdir -p "$APP_CODE_DIR" "$APP_DATA_DIR" "$APP_RUNTIME_DIR" "$APP_TMP_DIR" && \
    apt-get update && \
    apt-get install -y --no-install-recommends jq python3 ca-certificates curl openssl libjemalloc2 postgresql-client && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://repo.manticoresearch.com/GPG-KEY-manticore > /tmp/manticore.key && \
    curl -fsSL https://repo.manticoresearch.com/GPG-KEY-SHA256-manticore >> /tmp/manticore.key && \
    gpg --dearmor -o /usr/share/keyrings/manticore.gpg /tmp/manticore.key && \
    rm /tmp/manticore.key && \
    echo "deb [signed-by=/usr/share/keyrings/manticore.gpg] https://repo.manticoresearch.com/repository/manticoresearch_jammy/ jammy main" > /etc/apt/sources.list.d/manticore.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends manticore manticore-extra && \
    rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/share/manticore/modules/manticore-buddy/bin/manticore-buddy /usr/bin/manticore-buddy
RUN chown -R cloudron:cloudron /usr/share/manticore

# bring in the upstream runtime and packaged server artifacts
COPY --from=upstream /usr/local /usr/local
COPY --from=upstream /opt /opt
COPY --from=upstream /app "$APP_BUILD_DIR"

# configuration, launch scripts, and defaults
COPY start.sh "$APP_CODE_DIR/start.sh"
COPY run-affine.sh "$APP_CODE_DIR/run-affine.sh"
COPY run-manticore.sh "$APP_CODE_DIR/run-manticore.sh"
COPY run-buddy.sh "$APP_CODE_DIR/run-buddy.sh"
COPY nginx.conf "$APP_CODE_DIR/nginx.conf"
COPY supervisord.conf "$APP_CODE_DIR/supervisord.conf"
COPY config.example.json "$APP_CODE_DIR/config.example.json"
COPY tmp_data/ "$APP_TMP_DIR/"
COPY manticore/ "$APP_CODE_DIR/manticore/"

RUN chmod +x "$APP_CODE_DIR/start.sh" "$APP_CODE_DIR/run-affine.sh" "$APP_CODE_DIR/run-manticore.sh" "$APP_CODE_DIR/run-buddy.sh" && \
    chown cloudron:cloudron "$APP_CODE_DIR/start.sh" "$APP_CODE_DIR/run-affine.sh" "$APP_CODE_DIR/run-manticore.sh" "$APP_CODE_DIR/run-buddy.sh" && \
    chown -R cloudron:cloudron "$APP_DATA_DIR" "$APP_RUNTIME_DIR" "$APP_TMP_DIR"

EXPOSE 3000
CMD ["/app/code/start.sh"]
