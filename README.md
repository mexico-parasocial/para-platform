# para-platform

Punto de entrada único para levantar y diagnosticar la plataforma PARA. Este
repo **no contiene código de servicios**: une los que ya viven en cada repo y
agrega solo lo que pertenece a la plataforma (perfiles, el edge y el
diagnóstico).

| Repo | Qué es | Dónde corre |
| --- | --- | --- |
| WatZappa | Red AT Protocol (PLC, PDS, AppView, Ozone) y Matrix | servidor |
| mubEZ | Broker M8: identidad, INE, ZKP, llaves | servidor (aislado) |
| PARA | App (iOS, Android, web) | dispositivos / web |
| iM8 | Billetera de identidad | dispositivos |

Se espera esta estructura de carpetas (se puede cambiar en `.env`):

```
macserver/
  para-platform/   ← este repo
  WatZappa/
  mubEZ/
  PARA/
../iM8/
```

## Desarrollo local

En desarrollo los servicios corren como procesos (no contenedores). El orden:

1. `cd WatZappa && make run-dev-env-persistent` (PLC, PDS, AppView, chat)
2. `cd WatZappa/services/matrix-bridge && pnpm start`
3. `cd mubEZ && pnpm dev` (con `PLC_URL=http://localhost:2582` y
   `PDS_URL=http://localhost:2583` en `mubEZ/.env`)
4. `cd PARA && npx expo start --clear`

Luego, siempre que algo falle:

```bash
make doctor
```

`doctor` revisa, y en cada falla dice el comando que la arregla:

- **Servicios:** que cada puerto responda (PLC, PDS, AppView, chat, bridge,
  broker, introspección).
- **DIDs:** que el DID al que PARA hace proxy sea el del AppView en ejecución
  y exista en el PLC (el error "could not resolve proxy did").
- **Configuración:** que la IP o el nombre `.local` en `PARA/.env.local`
  apunten a esta Mac, y que mubEZ resuelva cuentas contra el PLC local.
- **Builds:** que ningún `dist/` sea más viejo que su `src/`, y que ningún
  proceso siga corriendo código anterior a su último build.
- **Repos:** en qué rama está cada uno y si tiene cambios sin commit.

## Producción

```bash
cp .env.example .env                              # PARA_DOMAIN, rutas, PROFILES
cp env/identity.env.example env/identity.env      # secretos de mubEZ
make doctor-prod                                  # revisa la configuración
make up                                           # levanta los perfiles de PROFILES
```

Perfiles (`make up PROFILES=core,edge`, etc.):

| Perfil | Servicios |
| --- | --- |
| `core` | Postgres, Redis, PDS, AppView (bsky + dataplane), bsync, Ozone |
| `matrix` | Synapse, MAS, para-idp, Element, matrix-bridge |
| `identity` | mubEZ |
| `edge` | Caddy: HTTPS y dominios públicos |

Otros comandos: `make ps`, `make logs S=mubez`, `make down`, `make config`
(muestra la configuración final sin levantar nada).

### El edge

Caddy es lo único expuesto a internet (puertos 80 y 443). Emite los
certificados HTTPS y reparte el tráfico por subdominio:

| Dominio | Servicio |
| --- | --- |
| `pds.PARA_DOMAIN` y `PARA_DOMAIN` | PDS |
| `appview.PARA_DOMAIN` | AppView |
| `ozone.PARA_DOMAIN` | Ozone |
| `bridge.PARA_DOMAIN` | matrix-bridge |
| `m8.PARA_DOMAIN` | mubEZ (broker M8) |

`edge/Caddyfile` importa el Caddyfile de WatZappa tal cual y solo agrega las
rutas de servicios de otros repos. Cada repo sigue siendo dueño de sus rutas.

### Seguridad de mubEZ

El `docker-compose.yml` de mubEZ es de desarrollo: fija `NODE_ENV=development`
y trae secretos por defecto. En development el broker entrega un token M8 para
**cualquier DID sin pruebas** (dev-token bootstrap). `overrides/identity.yaml`
reemplaza por completo ese bloque: fuerza producción, toma los secretos de
`env/identity.env` y no publica el puerto 8787 en el host (solo Caddy habla con
el broker). `make doctor-prod` revisa que los secretos existan, sean largos y
no parezcan de desarrollo, y que CORS no esté abierto.

### Autoridad de comunidades

Selecciona la revisión integrada de WatZappa antes de levantar la plataforma.
Define `PARA_AUTHORITY_SERVICE_TOKEN` en `.env` con una credencial dedicada de
32–512 caracteres; Compose la pasa explícitamente al AppView y al bridge. El
bridge consulta `https://appview.PARA_DOMAIN` por defecto; puedes definir
`BRIDGE_AUTHORITY_APPVIEW_URL` si el origen real es otro. No uses HTTP entre
nombres de contenedores: el resolver exige HTTPS salvo loopback local.

Durante la actualización, detén el bridge anterior, aplica las migraciones de
autoridad del AppView y después levanta la revisión integrada del bridge. Una
respuesta de salud no acredita autoridad: verifica roles falsificados, cambios
legítimos, reparación del estado previo y revocación en el homeserver real.
El procedimiento y el estado están en
[el registro de autoridad](../WatZappa/docs/TRUSTED-AUTHORITY-EXECUTION-2026-10-05.md).

### Aceptación del login de PARA

La configuración de producción debe habilitar el handoff OAuth y deshabilitar
el bootstrap de desarrollo. `env/identity.env.example` incluye los dos flags y
los callbacks; sustituye el origen web de ejemplo en CORS y en
`OAUTH_RETURN_TO_ALLOWLIST`. El callback nativo vigente es `para://m8-auth`.
Aplica primero las migraciones 040–041 del broker, después de respaldar su base.

Antes de probar los clientes, ejecuta dentro del broker desplegado:

```bash
make login-preflight WEB_ORIGIN=https://ORIGEN_WEB_REAL
```

El preflight revisa su entorno efectivo, las columnas/migraciones de la base en
modo lectura, los metadatos públicos, CORS y la ruta web `/m8-auth`. No crea
sesiones, emite tokens ni aplica migraciones. `--config-only` omite las llamadas
HTTP y no acredita conectividad. Fuera del contenedor, desde mubEZ, puedes usar
`pnpm login:preflight --web-origin https://ORIGEN_WEB_REAL`.

Un resultado correcto todavía exige registrar las revisiones desplegadas y
probar el proveedor real en iOS, Android y web. La web reconecta M8 al recargar.
El estado del piloto y la siguiente acción están en
[la cola canónica](../WatZappa/docs/QUARTER_PLAN_2026Q4.md), con evidencia en
[el registro de login](../WatZappa/docs/M8-LOGIN-EXECUTION-2026-10-05.md).

## Cómo está armado

- `compose.yaml` incluye `WatZappa/docker-compose.prod.yaml`,
  `WatZappa/docker-compose.matrix.yaml` y `mubEZ/docker-compose.yml`, cada uno
  con un override de `overrides/`. No se copia nada: si un repo cambia su
  compose, la plataforma lo toma.
- Todo queda en un solo proyecto de Compose (`para`), así que los servicios se
  ven por nombre (el bridge llama a `http://mubez:8787/v1`). La red externa
  `para-edge` se conserva para los despliegues antiguos por separado;
  `make up` la crea si falta.
- Requiere Docker Compose v2.24 o superior (`include` con varios archivos y
  `!override`).
