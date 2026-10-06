# Plataforma PARA — interfaz del administrador.
#
#   make help                 lista los comandos
#   make doctor               revisa el entorno local (procesos de desarrollo)
#   make up                   levanta los perfiles de PROFILES (ver .env)
#   make up PROFILES=core     levanta solo algunos perfiles

-include .env
export

PLATFORM_DIR := $(CURDIR)
export PLATFORM_DIR

PROFILES ?= core,matrix,identity,edge
comma := ,
PROFILE_FLAGS := $(foreach p,$(subst $(comma), ,$(PROFILES)),--profile $(p))
COMPOSE := docker compose $(PROFILE_FLAGS)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Muestra esta ayuda
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: doctor
doctor: ## Revisa servicios, DIDs, configuración y builds del entorno local
	@./scripts/doctor.sh dev

.PHONY: doctor-prod
doctor-prod: ## Revisa los endpoints públicos de PARA_DOMAIN
	@./scripts/doctor.sh prod

.PHONY: login-preflight
login-preflight: ## Revisa login sin emitir tokens (WEB_ORIGIN=https://tu-app)
	@test -n "$$WEB_ORIGIN" || { echo 'Define WEB_ORIGIN con el origen web real de PARA'; exit 2; }
	$(COMPOSE) exec mubez node build/bin/para_login_preflight.js --web-origin "$$WEB_ORIGIN"

.PHONY: network
network: ## Crea la red compartida para-edge si no existe
	@docker network inspect para-edge >/dev/null 2>&1 || docker network create para-edge

.PHONY: config
config: ## Valida y muestra la configuración final de Compose
	$(COMPOSE) config

.PHONY: up
up: network ## Construye y levanta los perfiles de PROFILES
	$(COMPOSE) up -d --build

.PHONY: down
down: ## Detiene los perfiles de PROFILES (conserva volúmenes)
	$(COMPOSE) down

.PHONY: ps
ps: ## Estado de los contenedores
	$(COMPOSE) ps

.PHONY: logs
logs: ## Logs en vivo (make logs S=mubez para un solo servicio)
	$(COMPOSE) logs -f --tail=200 $(S)
