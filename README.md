# zabbix-server-docker

Zabbix Server **7.0 LTS** con MySQL y frontend Nginx + PHP-FPM (imagen todo-en-uno
`zabbix-web-nginx-mysql`), listo para desplegar en un VPS con `git clone` + `.env` +
`docker compose up -d`. Incluye un `zabbix-agent2` activado por defecto para automonitorizar
el propio stack (MySQL, Nginx, PHP-FPM y el propio Zabbix server) con plantillas nativas.
Los defaults están pensados para un VPS **dedicado** de **2 GB de RAM** (nada más corre en la
máquina), con ruta clara para escalar a 4/8 GB (ver [Sizing de memoria](#sizing-de-memoria)).

## Requisitos

- Docker Engine + el plugin `docker compose` (Compose v2).
- `openssl` en el host (sólo para generar el certificado autofirmado inicial).
- Puertos 80 y 443 libres en el VPS (o cámbialos en `.env` / vía override).

## Instalación rápida

```bash
# Clona directamente en /opt/zabbix — todo el almacenamiento persistente vive dentro de
# esta misma carpeta (rutas relativas), así que mover/copiar /opt/zabbix mueve stack + datos.
sudo git clone <url-de-este-repo> /opt/zabbix
cd /opt/zabbix

cp .env.example .env
# Edita .env: como mínimo cambia MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD y MYSQL_MONITOR_PASSWORD.
nano .env

./scripts/generate-certs.sh   # certificado autofirmado para HTTPS (ver sección HTTPS abajo)

docker compose up -d
docker compose ps             # espera a que mysql-server y zabbix-server estén "healthy"
```

Frontend disponible en `https://<ip-o-dominio>/` (certificado autofirmado — normal que el
navegador avise si accedes directo, sin Cloudflare por delante). Login inicial: `Admin` / `zabbix`
— cámbialo enseguida.

## Estructura del repo

```
docker-compose.yml                      # stack base (mysql, zabbix-server, zabbix-web, zabbix-agent2)
docker-compose.override.yml.example     # plantilla de variaciones (copiar a .override.yml, no se commitea)
.env.example                            # plantilla de variables (copiar a .env, no se commitea)
env_vars/                               # tuning avanzado opcional por servicio (ver más abajo)
nginx/server-common.conf                # config nginx montada sobre la imagen (ver más abajo)
mysql-init/01-create-zbx-monitor-user.sh
caddy/Caddyfile.example                 # plantilla para el modo Let's Encrypt
scripts/generate-certs.sh
data/                                   # almacenamiento persistente (gitignored)
```

## HTTPS: autofirmado (por defecto), manual o Let's Encrypt

Por defecto `zabbix-web` publica 80/443 directo en el host con un certificado autofirmado
generado por `scripts/generate-certs.sh` en `data/nginx/ssl/`. Pensado para exponerse detrás
de **Cloudflare / cloudflared**, que ya se encargan del TLS público — el certificado del
origen sólo necesita existir, no ser válido para una CA pública.

- **Certificado propio (comprado, u otra CA)**: sustituye a mano
  `data/nginx/ssl/{ssl.crt,ssl.key,dhparam.pem}` y `docker compose restart zabbix-web`.
- **Let's Encrypt automático**: si en algún despliegue no vas a usar Cloudflare y quieres un
  certificado público real, hay un ejemplo listo en `docker-compose.override.yml.example`
  (Ejemplo 3) que añade un contenedor Caddy delante de `zabbix-web` y gestiona la renovación
  solo. Requiere el dominio apuntando al VPS y el puerto 80 accesible para el reto HTTP-01;
  no lo uses a la vez que el modo Cloudflare (ambos quieren el puerto 80/443).

## `docker-compose.override.yml`: variaciones sin tocar el compose base

Copia `docker-compose.override.yml.example` a `docker-compose.override.yml` (gitignored) y
edítalo. Compose lo aplica automáticamente en cada `up`. Ojo: las claves tipo lista (`ports`,
`volumes`, `profiles`...) se **reemplazan por completo**, no se concatenan — así es como el
ejemplo de Let's Encrypt puede desactivar limpiamente los `ports` de `zabbix-web`.

## Sobre `MYSQL_ROOT_PASSWORD`

Tiene dos usos, por eso conviene no borrarla del `.env` tras el primer arranque:

1. **Primer arranque**: `zabbix-server` la usa para crear la base de datos, el usuario
   `MYSQL_USER` y cargar el schema inicial. En arranques posteriores, con la BD ya poblada,
   no hace falta.
2. **Administración posterior**: te permite entrar como root al MySQL del stack sin exponer
   el puerto 3306 al exterior, por ejemplo para crear usuarios de monitorización:
   ```bash
   docker compose exec mysql-server mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
   ```
   Esto es justo lo que hace automáticamente `mysql-init/01-create-zbx-monitor-user.sh` en el
   primer arranque (crea el usuario `zbx_monitor` para la plantilla "MySQL by Zabbix agent 2").
   Si el volumen de `data/mysql` ya existía cuando añadiste este script, créalo a mano con el
   mismo comando de arriba y el SQL que hay dentro del script.

## Sizing de memoria

Los valores por defecto de `.env.example` asumen un **VPS dedicado** (nada más corre en la
máquina) de **2 GB de RAM** (p.ej. Linode 2 GB). Al no compartir la máquina con otras cargas, la
única reserva real que hace falta dejar libre es para el kernel + el propio daemon de Docker
(~300-500 MB, no escala con el tamaño del host) más margen ante picos — no "la mitad" de la RAM.
Por eso los límites usan **~83% de la RAM total** (~1.7 GB), y la mayor parte del presupuesto va
a `MYSQL_INNODB_BUFFER_POOL_SIZE`, que es la variable de mayor impacto real en el rendimiento
(menos I/O a disco al leer/escribir historial). El factor de riesgo #1 en cualquier VPS sigue
siendo **PHP-FPM**: el default de la imagen es `pm.max_children=50` y cada child ronda 30-50 MB
(hasta ~2 GB él solo si no se ajusta), por eso `PHP_FPM_PM_MAX_CHILDREN` y compañía van con un
valor explícito desde el primer `up`, no vacíos.

Para VPS más grandes, sube estas mismas variables en `.env` (no hace falta tocar el compose):

| Variable | 2 GB (default) | 4 GB | 8 GB |
|---|---|---|---|
| `MYSQL_INNODB_BUFFER_POOL_SIZE` | 512M | 1G | 2G |
| `MYSQL_MEM_LIMIT` | 896m | 1536m | 3g |
| `ZABBIX_SERVER_MEM_LIMIT` | 320m | 512m | 768m |
| `PHP_FPM_PM_MAX_CHILDREN` | 8 | 16 | 32 |
| `PHP_FPM_PM_START_SERVERS` | 2 | 4 | 8 |
| `PHP_FPM_PM_MIN_SPARE_SERVERS` | 2 | 3 | 6 |
| `PHP_FPM_PM_MAX_SPARE_SERVERS` | 4 | 8 | 16 |
| `ZABBIX_WEB_MEM_LIMIT` | 384m | 640m | 1024m |
| `ZABBIX_AGENT_MEM_LIMIT` | 96m | 128m | 192m |
| **Total límites** | **~1.7 GB (83%)** | **~2.8 GB (69%)** | **~4.9 GB (61%)** |

El % de uso baja a propósito en los tiers grandes: en 2 GB hay que aprovechar cada MB, pero en
4/8 GB sobra margen de todos modos para crecer (más hosts monitorizados, más items, más
retención de historial) sin tener que volver a tocar el sizing. Si tu VPS no es dedicado (corre
otras cosas además de este stack), baja estos valores en proporción al resto de la carga.
`pm.max_children` es orientativo — súbelo más si el frontend sirve a muchos usuarios
concurrentes. Confirma el consumo real tras el primer arranque con `docker compose stats`.

## Personalización avanzada (`env_vars/`)

Más allá de las variables de sizing de arriba, las imágenes oficiales de Zabbix ya soportan
muchísimas variables de entorno para tocar casi cualquier directiva de `zabbix_server.conf`,
`php.ini`/PHP-FPM o `zabbix_agent2.conf` sin editar archivos de configuración a mano ni
reconstruir imágenes — es el mismo mecanismo que usa el propio repo oficial
[`zabbix/zabbix-docker`](https://github.com/zabbix/zabbix-docker) (carpeta `env_vars/` con un
archivo por componente); aquí se replica igual, con los mismos nombres de variable.

Cada servicio carga opcionalmente un archivo `env_vars/<servicio>.env` (`required: false`: si
no existe, no pasa nada). Para usarlo:

```bash
cp env_vars/zabbix-server.env.example env_vars/zabbix-server.env
nano env_vars/zabbix-server.env   # descomenta lo que necesites
docker compose up -d zabbix-server
```

Disponibles: `env_vars/zabbix-server.env.example`, `env_vars/zabbix-web.env.example`,
`env_vars/zabbix-agent2.env.example`, `env_vars/mysql.env.example` — cada uno con la lista
completa de variables soportadas, comentada y agrupada por categoría (verificadas contra el
código fuente real de los entrypoints en `templates/entrypoints/` de la rama 7.0 de
`zabbix-docker`). Ejemplos de lo que habilitan:

- **`zabbix-server.env`**: más tipos de pollers (SNMP, ODBC, historial...), TLS servidor↔agente
  o servidor↔MySQL, HashiCorp Vault en vez de contraseña en claro, alta disponibilidad,
  VMware/SNMP traps/Java Gateway (si algún día añades esos contenedores), `ZBX_EXPORTTYPE` para
  exportar eventos/historial a NDJSON, etc.
- **`zabbix-web.env`**: límites de PHP (`ZBX_MEMORYLIMIT`, `ZBX_UPLOADMAXFILESIZE`...),
  restringir el acceso al frontend por IP (`ZBX_DENY_GUI_ACCESS`/`ZBX_GUI_ACCESS_IP_RANGE`), TLS
  frontend↔MySQL, SSO/SAML.
- **`zabbix-agent2.env`**: TLS agente↔servidor (PSK o certificados), restringir qué `keys`
  puede ejecutar (`ZBX_DENYKEY`/`ZBX_ALLOWKEY`), checks activos vs. pasivos, buffer persistente.

Las variables ya cableadas directamente en `.env` (`ZBX_STARTPOLLERS`, `PHP_FPM_PM_MAX_CHILDREN`,
etc. — ver `docker-compose.yml`) van ahí, no en `env_vars/`: si las repites en `env_vars/` no
tendrán efecto, porque el bloque `environment:` del compose tiene prioridad sobre `env_file:`.

**Scripts custom (`alertscripts`/`externalscripts`)**: esto no necesita nada de lo anterior, ya
funciona desde el primer `up` — sólo copia tus scripts a `./data/zabbix/alertscripts/` o
`./data/zabbix/externalscripts/` (montados en el contenedor `zabbix-server`) y referéncialos por
nombre desde Zabbix (Alertas → Métodos de notificación, o Data collection → Elementos de tipo
"Script externo").

## Monitorizar el propio stack (zabbix-agent2)

El contenedor `zabbix-agent2` viene activo por defecto, en la misma red interna que el resto,
listo para que el `zabbix-server` lo consulte. Para que reporte datos hace falta configurar
host(s) y plantillas **nativas** desde el frontend web (Data collection → Hosts):

- **Nginx** (host apuntando al agente, plantilla **"Nginx by Zabbix agent"**), macros:
  - `{$NGINX.STUB_STATUS.HOST}` = `zabbix-web`
  - `{$NGINX.STUB_STATUS.PORT}` = `8080`
  - `{$NGINX.STUB_STATUS.PATH}` = `nginx-status` *(la imagen usa `/nginx-status`, no el
    `/basic_status` que trae la plantilla por defecto)*
- **PHP-FPM** (mismo host, plantilla **"PHP-FPM by Zabbix agent"**), macros:
  - `{$PHP_FPM.HOST}` = `zabbix-web`
  - `{$PHP_FPM.PORT}` = `8080` *(`status`/`ping` ya coinciden con el default de la plantilla)*
  - El ítem de conteo de procesos (`proc.get`) no va a poblarse: PHP-FPM corre en el
    contenedor `zabbix-web`, no en el mismo PID-namespace que `zabbix-agent2`. Es una
    limitación conocida y asumida (no se comparte PID namespace entre contenedores para no
    acoplar su ciclo de vida).
- **MySQL** (plantilla **"MySQL by Zabbix agent 2"**), macros:
  - `{$MYSQL.DSN}` = `tcp://mysql-server:3306`
  - `{$MYSQL.USER}` = `zbx_monitor`
  - `{$MYSQL.PASSWORD}` = el valor de `MYSQL_MONITOR_PASSWORD` en tu `.env`
- **Linux/host del agente** (plantilla **"Linux by Zabbix agent"**): métricas del contenedor
  del propio agente, no del VPS completo. Para monitorizar el VPS entero haría falta montar
  `/proc`, `/sys`, etc. en `zabbix-agent2` — no incluido por defecto, es una extensión futura.
- **Salud del propio Zabbix server**: no usa agente. Activa el host predefinido
  **"Zabbix server"** (Data collection → Hosts) y adjúntale la plantilla **"Zabbix server
  health"** — son ítems internos que evalúa el propio server.

Nginx y PHP-FPM son alcanzables desde `zabbix-agent2` porque `nginx/server-common.conf`
(montado sobre la config de la imagen) abre esos endpoints a la subred interna de Compose
(`172.28.55.0/24` por defecto, definida en `docker-compose.yml`); si cambias esa subred,
actualiza también el `allow` en `nginx/server-common.conf`.

## Actualizar la versión de Zabbix

Cambia `ZBX_VERSION` en `.env` (p.ej. de `alpine-7.0-latest` a un patch concreto como
`alpine-7.0.11`) y:

```bash
docker compose pull
docker compose up -d
```

## Mover el stack a otra ruta/servidor

Gracias a las rutas relativas, basta con parar el stack, mover la carpeta completa y
levantarlo de nuevo desde la nueva ubicación:

```bash
docker compose down
mv /opt/zabbix /nueva/ruta/zabbix   # o rsync a otro servidor
cd /nueva/ruta/zabbix
docker compose up -d
```

## Diferencias deliberadas frente al repo oficial

Este repo usa las mismas imágenes oficiales y, para tuning avanzado, exactamente las mismas
variables de entorno que [`zabbix/zabbix-docker`](https://github.com/zabbix/zabbix-docker) (ver
sección anterior). Donde sí se simplifica deliberadamente, respecto a lo que trae ese repo por
defecto, es en la orquestación — pensado para un único VPS con un solo operador, no para un
despliegue organizacional grande:

| | Repo oficial (`zabbix-docker`) | Este repo | Por qué |
|---|---|---|---|
| Contraseñas | Docker Secrets (archivos en `env_vars/.MYSQL_ROOT_PASSWORD` etc.) | Variables en un único `.env` | Un solo archivo que editar cumple el objetivo de "clonar + `.env` + `up`"; en un VPS de un solo usuario el `.env` con permisos restrictivos es una amenaza aceptable. |
| Redes | 4 redes segmentadas (frontend/backend/database/tools) | 1 red (`zabbix-net`) | Con 4 contenedores en un solo host, la segmentación añade complejidad sin aportar aislamiento real adicional (todo corre bajo el mismo root de Docker). |
| `zabbix-agent2` | `privileged: true` + `pid: host`, detrás de un profile (no arranca por defecto) | Contenedor propio, sin privilegios, activo por defecto | Se decidió explícitamente automonitorizar el stack (MySQL/Nginx/PHP-FPM/Zabbix server) desde el primer `up`, sin exponer el host completo al contenedor. Monitorizar el VPS entero (CPU/disco/red del host) queda fuera de alcance por ahora. |
| Estructura de datos | Árbol profundo `./zbx_env/` que espeja cada ruta interna del contenedor | `./data/<servicio>/` plano | Más simple de inspeccionar/mover a mano; el conjunto de rutas montadas es un subconjunto reducido (sólo lo que este stack usa). |

Si en algún momento cambian las necesidades (varios VPS, múltiples operadores, requisitos de
aislamiento de red más estrictos), estas cuatro decisiones son las que revisar primero.

## Comandos útiles

```bash
docker compose logs -f zabbix-server   # logs de un servicio
docker compose ps                      # estado / healthchecks
docker compose down                    # parar (los datos en data/ persisten)
docker compose --env-file .env config  # validar el YAML resuelto
```
