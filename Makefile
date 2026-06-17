# =============================================================================
#  KAYDAN ERP — Makefile d'exploitation
#  Usage : make <cible>     ·     make help
# =============================================================================
SHELL := /bin/bash
COMPOSE := docker compose
PROJECT := kaydan-erp

.DEFAULT_GOAL := help

## ----------------------------------------------------------------------------
## Aide
## ----------------------------------------------------------------------------
.PHONY: help
help: ## Affiche cette aide
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;33m%-18s\033[0m %s\n", $$1, $$2}'

## ----------------------------------------------------------------------------
## Initialisation
## ----------------------------------------------------------------------------
.PHONY: secrets
secrets: ## Génère un .env à partir du template avec des secrets aléatoires
	@test -f .env && { echo "❌ .env existe déjà — supprimez-le d'abord"; exit 1; } || true
	@cp .env.example .env
	@for key in POSTGRES_PASSWORD PG_EXPORTER_PASSWORD ODOO_ADMIN_PASSWD REDIS_PASSWORD \
	            PGADMIN_DEFAULT_PASSWORD MINIO_ROOT_PASSWORD BACKUP_PASSPHRASE \
	            GF_SECURITY_ADMIN_PASSWORD; do \
	  secret=$$(openssl rand -base64 36 | tr -d '/+=' | cut -c1-40); \
	  sed -i.bak "s|^$$key=.*|$$key=$$secret|" .env; \
	done
	@rm -f .env.bak && chmod 600 .env
	@echo "✅ .env généré avec des secrets aléatoires. Renseignez DOMAIN et ACME_EMAIL."

.PHONY: tune
tune: ## Génère config/odoo/odoo.conf selon ODOO_PROFILE (.env) ou la RAM/CPU détectée
	@bash scripts/tune.sh

## ----------------------------------------------------------------------------
## Cycle de vie
## ----------------------------------------------------------------------------
.PHONY: build up down restart ps logs
build: ## Construit les images locales (backup)
	$(COMPOSE) build

up: tune ## Démarre toute la stack (génère d'abord odoo.conf)
	$(COMPOSE) up -d

down: ## Arrête la stack (conserve les volumes)
	$(COMPOSE) down

restart: ## Redémarre la stack
	$(COMPOSE) restart

ps: ## État des services
	$(COMPOSE) ps

logs: ## Logs en suivi (make logs S=odoo)
	$(COMPOSE) logs -f --tail=200 $(S)

## ----------------------------------------------------------------------------
## Odoo
## ----------------------------------------------------------------------------
.PHONY: odoo-shell odoo-update odoo-restart
odoo-shell: ## Shell Odoo (make odoo-shell DB=kaydan)
	$(COMPOSE) exec odoo odoo shell -c /etc/odoo/odoo.conf -d $(DB)

odoo-update: ## Met à jour un module (make odoo-update DB=kaydan M=kaydan_branding)
	$(COMPOSE) exec odoo odoo -c /etc/odoo/odoo.conf -d $(DB) -u $(M) --stop-after-init
	$(COMPOSE) restart odoo

odoo-restart: ## Redémarre uniquement Odoo
	$(COMPOSE) restart odoo

## ----------------------------------------------------------------------------
## Sauvegarde / Restauration
## ----------------------------------------------------------------------------
.PHONY: backup restore backup-list
backup: ## Lance une sauvegarde manuelle immédiate
	$(COMPOSE) exec backup /scripts/backup.sh

backup-list: ## Liste les sauvegardes disponibles
	@ls -lah backups/ 2>/dev/null || echo "Aucune sauvegarde"

restore: ## Restauration interactive (make restore DB=kaydan FILE=backups/daily/kaydan_xxx.dump.gpg)
	$(COMPOSE) exec backup /scripts/restore.sh $(DB) $(FILE)

## ----------------------------------------------------------------------------
## Sécurité
## ----------------------------------------------------------------------------
.PHONY: harden audit
harden: ## (HÔTE/root) Durcissement système : UFW, Fail2Ban, SSH, logrotate
	@sudo bash security/harden.sh

audit: ## (HÔTE) Audit de sécurité rapide
	@sudo bash security/audit.sh

## ----------------------------------------------------------------------------
## Monitoring
## ----------------------------------------------------------------------------
.PHONY: reload-prometheus
reload-prometheus: ## Recharge la configuration Prometheus à chaud
	$(COMPOSE) exec prometheus kill -HUP 1 || curl -fsS -X POST http://localhost:9090/-/reload
