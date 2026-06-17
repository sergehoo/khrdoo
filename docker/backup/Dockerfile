# =============================================================================
#  Image de sauvegarde Kaydan ERP
#  Base postgres:16 (pg_dump/pg_restore alignés sur le serveur) + outils
# =============================================================================
FROM postgres:16-bookworm

ARG TARGETARCH=amd64
ARG SUPERCRONIC_VERSION=v0.2.33

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash gnupg tar gzip findutils coreutils ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/*

# MinIO client (mc) — pour l'envoi des sauvegardes vers le stockage objet S3
RUN curl -fsSL "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/mc" \
        -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

# supercronic — ordonnanceur cron fiable pour conteneurs
RUN curl -fsSL "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
        -o /usr/local/bin/supercronic \
    && chmod +x /usr/local/bin/supercronic

COPY entrypoint.sh /usr/local/bin/backup-entrypoint.sh
RUN chmod +x /usr/local/bin/backup-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/backup-entrypoint.sh"]
