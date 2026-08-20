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
# Edita .env: busca los 2 campos marcados ⚠️ OBLIGATORIO (MYSQL_PASSWORD, MYSQL_MONITOR_PASSWORD)
# y cámbialos. El resto ya trae defaults razonables (incluida la contraseña root de MySQL, que
# es opcional — ver "Sobre MYSQL_ROOT_PASSWORD" más abajo).
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

## ¿Por qué MySQL 8.4 y no MariaDB o PostgreSQL+TimescaleDB?

Zabbix 7.0 soporta oficialmente MySQL (8.0.30-9.7.x, incluyendo 8.4.x desde 7.0.1), MariaDB
(10.5-12.3.x) y PostgreSQL (con o sin TimescaleDB) por igual. La elección aquí no es "porque
upstream lo hace así", sino esto:

- **MySQL vs. MariaDB**: a la escala de un VPS personal (no miles de hosts), el rendimiento
  entre ambos motores es prácticamente idéntico — ambos usan InnoDB, mismo protocolo, Zabbix
  los trata igual. No hay un motivo técnico de peso para elegir uno u otro; es indistinto.
  Este repo usa **MySQL 8.4** (el release LTS vigente de Oracle, con horizonte de soporte más
  largo que 8.0). Cambiar a MariaDB, si algún día conviene, es tan simple como cambiar
  `image: mysql:...` por `image: mariadb:...` en `docker-compose.yml` — usa las mismas
  variables `MYSQL_*` y el mismo mecanismo de `docker-entrypoint-initdb.d`.
- **PostgreSQL + TimescaleDB**: se evaluó y se descartó para este despliegue. Su ventaja real
  (particionado automático de las tablas de historial/trends vía hypertables) sólo importa
  cuando el housekeeping tiene que borrar sobre tablas enormes — muchos hosts, retención larga.
  En un VPS personal ese escenario no aplica: MySQL sin particionar va sobrado. A cambio,
  migrar costaría reescribir el init de la BD (Zabbix requiere correr un script
  `timescaledb.sql` aparte del schema normal, no 100% automático como con MySQL) y rehacer toda
  la plantilla nativa de monitorización de la BD que ya está montada aquí ("MySQL by Zabbix
  agent 2" → "PostgreSQL by Zabbix agent 2": otro usuario, otras macros, otros grants). Si el
  despliegue creciera mucho a futuro (cientos de hosts, retención larga), vale la pena
  reconsiderar esto — hoy no se justifica.

## Sobre `MYSQL_ROOT_PASSWORD`

Es **opcional**. Zabbix en sí no la necesita en ningún momento: `zabbix-server` crea el schema
usando directamente `MYSQL_USER`/`MYSQL_PASSWORD` (ese usuario ya es dueño de la base de datos
`MYSQL_DATABASE` desde que la crea la propia imagen de MySQL, así que le alcanza para crear las
tablas sin ser root) — esto es exactamente lo que hace también el repo oficial
`zabbix/zabbix-docker`, que tampoco le pasa la contraseña root a sus componentes de Zabbix.

El único que sí necesita una cuenta con privilegios root dentro de este stack es nuestro propio
`mysql-init/01-create-zbx-monitor-user.sh`, porque `GRANT ... ON *.*` (privilegios globales, los
que pide la plantilla "MySQL by Zabbix agent 2") sólo los puede otorgar una cuenta con
privilegios de administrador — un usuario con todos los privilegios sólo sobre `zabbix`.* no
alcanza.

Por eso, por defecto:

- `MYSQL_RANDOM_ROOT_PASSWORD=yes` en `.env.example` — MySQL genera una contraseña root al azar
  en el primer arranque. El script de arriba la recibe automáticamente (el entrypoint de la
  imagen la deja disponible en el entorno antes de correr los scripts de init), así que
  `zbx_monitor` se crea igual sin que tengas que hacer nada. La contraseña generada queda **una
  sola vez** en el log: `docker compose logs mysql-server | grep "GENERATED ROOT PASSWORD"`.
- Si más adelante quieres entrar como root a mano (por ejemplo para crear otro usuario de
  monitorización, o inspeccionar algo con privilegios), necesitas conocer esa contraseña. Dos
  opciones: capturarla de los logs del primer arranque, o mejor, fijar tú una desde el inicio:
  ```bash
  # En .env, antes del primer "docker compose up -d":
  MYSQL_ROOT_PASSWORD=tu-contraseña
  #MYSQL_RANDOM_ROOT_PASSWORD=yes   # coméntala o bórrala — si dejas las dos, la aleatoria gana
  ```
  ```bash
  docker compose exec mysql-server mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
  ```
- Si el volumen de `data/mysql` ya existía cuando añadiste `01-create-zbx-monitor-user.sh` (no
  llegó a correr en el primer arranque), créalo a mano con el comando de arriba y el SQL que hay
  dentro del script — necesitas la contraseña root de ese primer arranque para entrar.

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
- **Salud del propio Zabbix server**: no usa agente. Activa el host predefinido
  **"Zabbix server"** (Data collection → Hosts) y adjúntale la plantilla **"Zabbix server
  health"** — son ítems internos que evalúa el propio server.

No adjuntes la plantilla **"Linux by Zabbix agent"** a este host: como `zabbix-agent2` corre en
su propio contenedor, esos ítems miden el contenedor del agente (unos pocos MB de RAM, un
proceso), no el VPS real — datos que no aportan nada. Deja este host sólo con las plantillas de
Nginx, PHP-FPM, MySQL y Zabbix server de arriba. Para monitorizar el VPS de verdad, ver la
siguiente sección.

Nginx y PHP-FPM son alcanzables desde `zabbix-agent2` porque `nginx/server-common.conf`
(montado sobre la config de la imagen) abre esos endpoints a la subred interna de Compose
(`172.28.55.0/24` por defecto, definida en `docker-compose.yml`); si cambias esa subred,
actualiza también el `allow` en `nginx/server-common.conf`.

## Monitorizar el VPS y Docker (agente aparte, fuera de este stack)

El `zabbix-agent2` de este repo corre deliberadamente sin privilegios, en su propio contenedor
(ver tabla de [diferencias frente al repo oficial](#diferencias-deliberadas-frente-al-repo-oficial))
— por diseño no tiene acceso al host, así que no puede reportar CPU/disco/red reales del VPS ni
el estado del propio Docker. Si quieres esas métricas, la forma recomendada es instalar un
**segundo `zabbix-agent2` directamente en el host** (paquete oficial de Zabbix para tu distro, o
un contenedor aparte con `network_mode: host` — pero en cualquier caso fuera de este
`docker-compose.yml`, para no tener que quitarle el aislamiento al stack principal).

Conéctalo al `zabbix-server` de este stack en **modo activo** (`Active checks`), no pasivo: el
puerto `${ZABBIX_SERVER_PORT:-10051}` ya está publicado al host, así que el agente nuevo sólo
necesita salir hacia `127.0.0.1:${ZABBIX_SERVER_PORT:-10051}` (o la IP del VPS) — no hace falta
abrir ni exponer ningún puerto adicional, ni resolver cómo alcanzar el host desde dentro de la
red de Docker (que sí haría falta en modo pasivo). En `zabbix_agent2.conf` del host:

```
Hostname=<algo-distinto-de-zabbix-agent, p.ej. el hostname del VPS>
ServerActive=127.0.0.1:10051
```

Plantillas nativas para este host nuevo:
- **"Linux by Zabbix agent"**: ahora sí son las métricas reales del VPS (CPU, memoria, disco,
  red), no las del contenedor.
- **"Docker by Zabbix agent 2"**: usa el plugin nativo de Docker de agent2, que lee
  `/var/run/docker.sock` — necesita que el agente (o su contenedor, si lo corres así) tenga
  acceso a ese socket. Macros típicos: `{$DOCKER.API.PROTOCOL}` = `unix`,
  `{$DOCKER.API.URI}` = `/var/run/docker.sock`.

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
