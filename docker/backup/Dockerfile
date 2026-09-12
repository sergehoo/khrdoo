# =============================================================================
#  Image de sauvegarde Kaydan ERP
#  Base postgres:16 (pg_dump/pg_restore alignés sur le serveur) + outils
# =============================================================================
FROM postgres:16-bookworm

ARG TARGETARCH=amd64
ARG SUPERCRONIC_VERSION=v0.2.33
# mc n'est PLUS distribué sur dl.min.io (HTTP 410 depuis 2026) : on prend la
# release GitHub, épinglée pour des builds reproductibles.
ARG MC_VERSION=RELEASE.2025-08-13T08-35-41Z

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash gnupg tar gzip findutils coreutils ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/*

# MinIO client (mc) — envoi des sauvegardes vers le stockage objet S3.
# ⚠ NON BLOQUANT : l'indisponibilité d'un binaire tiers ne doit jamais empêcher
# un déploiement. Sans mc, backup.sh produit quand même les archives LOCALES et
# signale simplement que l'envoi S3 est impossible.
RUN set -eux; \
    if curl -fsSL --retry 3 --retry-delay 2 \
         "https://github.com/minio/mc/releases/download/${MC_VERSION}/mc.linux-${TARGETARCH}.${MC_VERSION}" \
         -o /usr/local/bin/mc; then \
      chmod +x /usr/local/bin/mc; \
      /usr/local/bin/mc --version || true; \
    else \
      echo "AVERTISSEMENT : client mc non téléchargé — l'envoi S3 sera désactivé"; \
      rm -f /usr/local/bin/mc; \
    fi

# supercronic — ordonnanceur cron fiable pour conteneurs
RUN curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
        -o /usr/local/bin/supercronic \
    && chmod +x /usr/local/bin/supercronic

COPY entrypoint.sh /usr/local/bin/backup-entrypoint.sh
RUN chmod +x /usr/local/bin/backup-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/backup-entrypoint.sh"]
