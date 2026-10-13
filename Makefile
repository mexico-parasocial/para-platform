# Plataforma PARA — un solo punto de entrada para desarrollar y operar.
#
#   make help        lista los comandos
#
# Desarrollo:  make setup  →  make dev   (todo el entorno local, un comando)
# Producción:  make secrets → make preflight → make up → make verify

-include .env
export

PLATFORM_DIR := $(CURDIR)
export PLATFORM_DIR

WATZAPPA_DIR ?= ../WatZappa
MUBEZ_DIR ?= ../mubEZ
PARA_DIR ?= ../PARA
PARA_PROFILE ?= tiny
PROFILES ?= core,matrix,identity,edge
comma := ,
PROFILE_FLAGS := $(foreach p,$(subst $(comma), ,$(PROFILES)),--profile $(p))

# Valores que salen de PARA_DOMAIN si .env no los fija. Se exportan para que
# los compose de cada repo los interpolen sin conocer la plataforma.
BSKY_SERVER_DID ?= did:web:appview.$(PARA_DOMAIN)
OZONE_SERVER_DID ?= did:web:ozone.$(PARA_DOMAIN)
MATRIX_SERVER_NAME ?= matrix.$(PARA_DOMAIN)
MATRIX_PUBLIC_HOMESERVER_URL ?= https://matrix.$(PARA_DOMAIN)
MATRIX_DOMAIN ?= chat.$(PARA_DOMAIN)
POSTGRES_USER ?= pg
PARA_SECRETS_GID ?= 10001
PARA_HANDLE_DOMAIN ?= .$(PARA_DOMAIN)
# Salas nuevas cifradas: el chat nativo de PARA rechaza las que no lo están
# (ENCRYPTED_ROOM_REQUIRED). No cifra salas que ya existen.
MATRIX_ENABLE_ENCRYPTION ?= true
MATRIX_ADMIN_USER ?= para-bridge-admin

# El edge publica las rutas de cada perfil solo si el perfil está activo.
has_profile = $(findstring $(comma)$(1)$(comma),$(comma)$(PROFILES)$(comma))
PARA_EDGE_MATRIX_SITE := $(if $(call has_profile,matrix),$(abspath $(WATZAPPA_DIR))/services/caddy/Caddyfile.matrix.prod,$(PLATFORM_DIR)/edge/sites/empty.Caddyfile)
PARA_EDGE_IDENTITY_SITE := $(if $(call has_profile,identity),$(PLATFORM_DIR)/edge/sites/identity.Caddyfile,$(PLATFORM_DIR)/edge/sites/empty.Caddyfile)
PARA_WEB_CONTEXT := $(abspath $(PARA_DIR))
PARA_ROOT_HANDLER := $(if $(call has_profile,web),reverse_proxy web:8100,respond "Not Found" 404)

# Variables que los compose de WatZappa interpolan y que en la plataforma
# llegan por otro lado (archivos de secrets/ o el bucket de .env). Vacías a
# propósito: así Compose no avisa que faltan y nada secreto viaja en el entorno.
PDS_BLOBSTORE_S3_BUCKET ?= $(S3_BUCKET)
PDS_BLOBSTORE_S3_ENDPOINT ?= $(S3_ENDPOINT)
PDS_BLOBSTORE_S3_ACCESS_KEY_ID ?=
PDS_BLOBSTORE_S3_SECRET_ACCESS_KEY ?=
PDS_RATE_LIMIT_BYPASS_KEY ?=
BSKY_SERVICE_SIGNING_KEY ?=
ADMIN_PASSWORDS ?=
MATRIX_ADMIN_TOKEN ?=
ADMIN_DIDS ?=

# El perfil da los tamaños; lo que ponga .env (ya exportado) le gana.
# Un worker de AppView (PARA_ROLE=appview-worker) usa compose.worker.yaml.
PARA_ROLE ?= primary
ifeq ($(PARA_ROLE),appview-worker)
COMPOSE := docker compose -f compose.worker.yaml --env-file profiles/$(PARA_PROFILE).env --profile appview-worker
else
COMPOSE := docker compose --env-file profiles/$(PARA_PROFILE).env $(PROFILE_FLAGS)
endif

.DEFAULT_GOAL := help

.PHONY: help
help: ## Muestra esta ayuda
	@awk 'BEGIN {FS = ":.*## "} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} /^[a-z-]+:.*## / {printf "  \033[36m%-19s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo

##@ Desarrollo (tu máquina)

.PHONY: setup
setup: ## Deja la máquina lista: herramientas, repos, dependencias, mubEZ/.env
	@./scripts/setup.sh

.PHONY: dev
dev: ## Todo el entorno local en una terminal (APP=web|ios|android MATRIX=1 FRESH=1)
	@./scripts/dev.sh

.PHONY: dev-app-env
dev-app-env: ## Apunta PARA/.env.local a esta Mac (IP y DID del AppView)
	@./scripts/dev-app-env.sh $(IP)

.PHONY: dev-logs
dev-logs: ## Sigue los logs de make dev (S=atproto|m8; sin S, todos)
	@tail -n 100 -F $(if $(S),.dev/logs/$(S).log,.dev/logs/*.log)

.PHONY: app-env
app-env: ## Variables para compilar la app PARA contra esta plataforma (EAS / build web)
	@./scripts/app-env.sh

.PHONY: seed
seed: ## Cuentas de prueba y memes en el PDS local (make dev debe estar arriba)
	@cd "$(WATZAPPA_DIR)" && ./scripts/seed-test-accounts.sh && $(MAKE) -s seed-memes-persistent

.PHONY: dev-down
dev-down: ## Apaga Postgres/Redis de desarrollo (los datos se conservan)
	@cd "$(WATZAPPA_DIR)/packages/dev-infra" && docker compose stop db redis

.PHONY: dev-reset
dev-reset: ## Borra los datos locales persistentes (pide confirmación)
	@printf 'Esto borra cuentas, posts y la base local de desarrollo. ¿Seguro? [y/N] ' && read a && [ "$$a" = y ]
	@cd "$(WATZAPPA_DIR)/packages/dev-infra" && docker compose rm -sf db redis && docker volume rm -f dev-infra_atp_db dev-infra_atp_redis >/dev/null
	@rm -rf "$(WATZAPPA_DIR)/.dev-env-data"
	@echo "Listo. El próximo make dev arranca de cero (luego: make dev-app-env)."

.PHONY: doctor
doctor: ## Revisa servicios, DIDs, configuración y builds del entorno local
	@./scripts/doctor.sh dev

.PHONY: e2e-dm
e2e-dm: ## Prueba punta a punta de los mensajes directos por Matrix (aislada, solo Docker)
	@./scripts/e2e-dm.sh

##@ Producción (el servidor)

.PHONY: secrets
secrets: ## Genera los secretos que falten en secrets/ (nunca pisa los existentes)
	@./scripts/secrets.sh generate

.PHONY: secrets-import
secrets-import: ## Trae los secretos de los .env de antes (WatZappa/.env, env/identity.env)
	@./scripts/secrets.sh import

.PHONY: preflight
preflight: ## Revisa configuración, secretos, bucket y DNS antes de levantar
	@./scripts/preflight.sh

.PHONY: up
up: network ## Descarga las imágenes fijadas y levanta PROFILES (BUILD=1 construye aquí; UP_ARGS=--force-recreate tras cambiar un secreto)
ifeq ($(BUILD),1)
	$(COMPOSE) up -d --build --wait --wait-timeout 900 $(UP_ARGS)
else
	$(if $(filter primary,$(PARA_ROLE)),$(COMPOSE) build backup)
	$(COMPOSE) pull --ignore-pull-failures --quiet
	$(COMPOSE) up -d --no-build --wait --wait-timeout 900 $(UP_ARGS)
endif

.PHONY: verify
verify: ## Comprueba el despliegue: contenedores, endpoints públicos, respaldos
	@./scripts/verify.sh

# Solo las versiones que pasas en la línea de comandos se escriben en .env.
UPGRADE_SET := $(if $(filter command line,$(origin WATZAPPA_VERSION)),WATZAPPA_VERSION $(WATZAPPA_VERSION)) \
               $(if $(filter command line,$(origin MUBEZ_VERSION)),MUBEZ_VERSION $(MUBEZ_VERSION))

.PHONY: upgrade
upgrade: ## Cambia de versión: make upgrade WATZAPPA_VERSION=sha-... [MUBEZ_VERSION=...]
	@test -n "$(strip $(UPGRADE_SET))" || { echo 'Pasa WATZAPPA_VERSION=... y/o MUBEZ_VERSION=...'; exit 2; }
	@./scripts/set-env.sh $(UPGRADE_SET)
	$(COMPOSE) pull --ignore-pull-failures --quiet
	$(COMPOSE) up -d --no-build --wait --wait-timeout 900
	@./scripts/verify.sh

.PHONY: down
down: ## Detiene PROFILES (conserva volúmenes y el bucket)
	$(COMPOSE) down

.PHONY: stop
stop: ## Detiene un servicio sin borrarlo (make stop S=pds)
	$(COMPOSE) stop $(S)

.PHONY: restart
restart: ## Reinicia con gracia (make restart S=bsky)
	$(COMPOSE) restart $(S)

.PHONY: ps
ps: ## Estado de los contenedores
	$(COMPOSE) ps

.PHONY: logs
logs: ## Logs en vivo (make logs S=mubez para un solo servicio)
	$(COMPOSE) logs -f --tail=200 $(S)

.PHONY: config
config: ## Valida y muestra la configuración final de Compose
	$(COMPOSE) config

.PHONY: compose
compose: ## Cualquier comando de Compose con la config de la plataforma (ARGS="...")
	@$(COMPOSE) $(ARGS)

.PHONY: network
network:
	@docker network inspect para-edge >/dev/null 2>&1 || docker network create para-edge >/dev/null

##@ Operación

.PHONY: doctor-prod
doctor-prod: ## Diagnóstico de producción: configuración y endpoints públicos
	@./scripts/doctor.sh prod

.PHONY: backup
backup: ## Corre un respaldo ahora (además del automático)
	$(COMPOSE) exec backup backup.sh once
	@case ",$(PROFILES)," in *,matrix,*) $(COMPOSE) exec backup-media backup.sh once ;; esac

.PHONY: restore
restore: ## Restaura del bucket (ARGS="list" | "postgres para latest" | "pds latest"); ver docs/RESPALDOS.md
	$(COMPOSE) run --rm --no-deps backup restore.sh $(ARGS)

.PHONY: restore-media
restore-media: ## Restaura el media de Synapse desde el bucket (detén synapse antes)
	$(COMPOSE) run --rm --no-deps -v $${COMPOSE_PROJECT_NAME:-para}_synapse_data:/restore/synapse backup-media restore.sh synapse-media

.PHONY: db-init
db-init: ## Crea las bases compartidas (matrix, mas, bridge) en un Postgres que ya existía
	$(COMPOSE) exec -u postgres postgres sh /docker-entrypoint-initdb.d/10-para-databases.sh

# Las URLs públicas que ven los navegadores y la app: MAS en auth., para-idp
# en idp., Element en chat. La config de Element queda junto a la de Synapse
# (no versionada) para que el checkout del servidor siga limpio.
MATRIX_INIT_ENV = POSTGRES_PASSWORD="$$(cat secrets/postgres_password)" \
	MATRIX_SERVER_NAME="$(MATRIX_SERVER_NAME)" MATRIX_DOMAIN="$(MATRIX_DOMAIN)" \
	MAS_PUBLIC_BASE="https://auth.$(PARA_DOMAIN)/" PARA_IDP_PUBLIC_URL="https://idp.$(PARA_DOMAIN)" \
	ELEMENT_CONFIG_OUT="$(abspath $(WATZAPPA_DIR))/deploy/matrix/synapse/element-config.json" \
	PARA_PUBLIC_URL="https://$(PARA_DOMAIN)"

.PHONY: matrix-init
matrix-init: ## Genera la configuración de Synapse, MAS y Element para PARA_DOMAIN (una vez)
	@test -s secrets/postgres_password || { echo 'Primero: make secrets'; exit 2; }
	@case "$(PARA_DOMAIN)" in ''|example.org) echo 'Define PARA_DOMAIN en .env'; exit 2 ;; esac
	@$(MATRIX_INIT_ENV) "$(WATZAPPA_DIR)/deploy/matrix/setup.sh"
	@$(MATRIX_INIT_ENV) "$(WATZAPPA_DIR)/deploy/matrix/setup-mas.sh"
	@$(MATRIX_INIT_ENV) BRIDGE_APPSERVICE_URL=http://matrix-bridge:3001 "$(WATZAPPA_DIR)/deploy/matrix/setup-appservice.sh"
	@./scripts/secrets.sh import | grep -E 'matrix_|importados' || true
	@echo
	@echo "Con la plataforma arriba falta el token de admin: make matrix-admin-token (docs/MATRIX.md)."

.PHONY: invite
invite: ## Crea un código de invitación del PDS (USES=1)
	@$(COMPOSE) exec -T pds sh -c 'wget -qO- --header "Content-Type: application/json" \
	  --header "Authorization: Basic $$(printf "admin:%s" "$$(cat "$$PDS_ADMIN_PASSWORD_FILE")" | base64 | tr -d "\n")" \
	  --post-data "{\"useCount\":$(or $(USES),1)}" http://127.0.0.1:2583/xrpc/com.atproto.server.createInviteCode'; echo

.PHONY: matrix-admin-token
matrix-admin-token: ## Usuario admin de Synapse para el bridge (vía MAS) y su token en secrets/
	@$(COMPOSE) exec -T mas mas-cli manage register-user --config /config/config.yaml --yes --admin "$(MATRIX_ADMIN_USER)" >/dev/null 2>&1 || true
	@out="$$($(COMPOSE) exec -T mas mas-cli manage issue-compatibility-token --config /config/config.yaml \
	    --yes-i-want-to-grant-synapse-admin-privileges "$(MATRIX_ADMIN_USER)" 2>&1)"; \
	  token="$$(printf '%s' "$$out" | grep -oE 'mct_[A-Za-z0-9_]+' | tail -1)"; \
	  if [ -z "$$token" ]; then echo "$$out" | tail -5; echo 'No obtuve el token (ver arriba)'; exit 1; fi; \
	  chmod u+w secrets 2>/dev/null; printf '%s' "$$token" > secrets/matrix_admin_token; \
	  ./scripts/secrets.sh perms >/dev/null; \
	  echo "Token de $(MATRIX_ADMIN_USER) en secrets/matrix_admin_token. Ahora: make up UP_ARGS=--force-recreate"

.PHONY: login-preflight
login-preflight: ## Revisa login sin emitir tokens (WEB_ORIGIN=https://tu-app)
	@test -n "$$WEB_ORIGIN" || { echo 'Define WEB_ORIGIN con el origen web real de PARA'; exit 2; }
	$(COMPOSE) exec mubez node build/bin/para_login_preflight.js --web-origin "$$WEB_ORIGIN"

.PHONY: deploy
deploy: ## Provisiona y despliega con Ansible (INVENTORY=deploy/ansible/inventories/<nombre>)
	@test -n "$(INVENTORY)" || { echo 'Define INVENTORY=deploy/ansible/inventories/<nombre>'; exit 2; }
	cd deploy/ansible && ansible-playbook -i "$(abspath $(INVENTORY))/hosts.yml" playbooks/site.yml $(ANSIBLE_ARGS)

##@ Este repo

.PHONY: check
check: ## Valida scripts, Compose, Caddyfile, alertas, Alloy y Ansible (usa Docker)
	@./scripts/check.sh
