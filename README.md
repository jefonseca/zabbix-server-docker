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

**El primer arranque tarda, y es normal**: con la base de datos vacía, `zabbix-server` importa
el schema completo (miles de sentencias SQL, incluidas todas las plantillas por defecto) antes
de quedar `healthy` — en un VPS modesto puede tardar **2-4 minutos** (medido: ~174s en un VPS
de 2 GB). Mientras tanto es normal ver `zabbix-zabbix-server-1  Up ... (health: starting)` en
`docker compose ps`. Sólo pasa esta vez: en reinicios posteriores el schema ya existe y arranca
en segundos. Si de todos modos ves `dependency failed to start` porque tu VPS es más lento
todavía que el margen de 240s que trae el healthcheck, simplemente vuelve a correr
`docker compose up -d` — `zabbix-server` sigue importando en segundo plano y termina bien.

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
- **Origin Certificate de Cloudflare** (recomendado si ya usas Cloudflare delante): en vez de un
  autofirmado genérico, usa el certificado que emite la propia Cloudflare para el origen —
  válido 15 años, gratis, y Cloudflare sólo confía en certificados suyos o firmados por su CA
  cuando el modo SSL/TLS está en "Full (strict)". Cloudflare no entrega un `dhparam.pem` (no es
  parte de un certificado, es un parámetro de intercambio de claves de nginx), así que ese
  archivo lo sigues generando tú:
  1. En el dashboard de Cloudflare: **SSL/TLS → Origin Server → Create Certificate** (deja las
     opciones por defecto: RSA 2048, 15 años). Te da un PEM de certificado y uno de clave
     privada — descárgalos o cópialos.
  2. Guárdalos como `data/nginx/ssl/ssl.crt` (el certificado) y `data/nginx/ssl/ssl.key` (la
     clave privada).
  3. Genera sólo el `dhparam.pem` que falta, sin tocar los archivos que acabas de poner:
     `./scripts/generate-certs.sh --dhparam-only`
  4. En Cloudflare, pon el modo SSL/TLS en **Full (strict)** (Full a secas también funciona,
     pero sin verificar que el origen sea realmente Cloudflare) y `docker compose restart
     zabbix-web`.
- **Let's Encrypt automático**: para cuando no quieres pasar por Cloudflare y prefieres un
  certificado público real, validado por una CA de verdad, gestionado sin intervención manual.
  Añade un contenedor Caddy delante de `zabbix-web` que obtiene el certificado (reto HTTP-01) y
  lo renueva solo, sin cron ni pasos manuales — todo vive en `data/caddy/` (gitignored,
  persistente entre reinicios).

  **Requisitos, antes de tocar nada:**
  - Un dominio/subdominio con un registro **A** (o AAAA) apuntando a la IP pública del VPS.
  - El **puerto 80 alcanzable desde internet** en esa IP: ábrelo en el firewall del proveedor
    (grupo de seguridad, etc.) y en el del propio VPS (`ufw allow 80,443/tcp` o equivalente).
    Caddy lo necesita para el reto HTTP-01; también sirve para redirigir a 443.
  - Si el dominio está en Cloudflare pero **no** quieres usar su proxy (este modo es alternativo
    al de Cloudflare, no se combinan), pon el registro en **"DNS only"** (nube gris, no naranja)
    mientras dure la validación — con el proxy naranja activado, Cloudflare intercepta el
    puerto 80 y el reto HTTP-01 nunca llega a Caddy.
  - No dejes `scripts/generate-certs.sh` publicando nada por delante: este modo hace que
    `zabbix-web` deje de exponer 80/443 directamente (ver override abajo), así que el
    autofirmado deja de usarse.

  **Pasos:**
  1. `cp caddy/Caddyfile.example caddy/Caddyfile` y edítalo: cambia `zabbix.tu-dominio.com` por
     tu dominio real y, opcionalmente, descomenta la línea `tls tu-email@...` para recibir
     avisos de Let's Encrypt si el certificado no llegara a renovarse solo.
  2. `cp docker-compose.override.yml.example docker-compose.override.yml` y descomenta el
     bloque completo del **Ejemplo 3** (el servicio `zabbix-web` con `ports: []` y el nuevo
     servicio `caddy`).
  3. `docker compose up -d` — Caddy arranca, pide el certificado a Let's Encrypt automáticamente
     y lo guarda en `data/caddy/data/`. Sigue el proceso con
     `docker compose logs -f caddy` (busca `certificate obtained successfully`); suele tardar
     pocos segundos si el DNS y el puerto 80 están bien.
  4. Ya puedes entrar por `https://zabbix.tu-dominio.com` con un certificado válido de verdad,
     sin avisos del navegador.

  **Renovación:** automática, Caddy la gestiona internamente (~30 días antes de vencer) mientras
  el contenedor siga corriendo; no hace falta cron ni tocar nada.

  **Si falla el reto HTTP-01** (el log de Caddy no llega a "certificate obtained"), lo más común
  es alguna de estas tres cosas: el registro DNS todavía no propagó (`dig +short
  zabbix.tu-dominio.com` debería devolver la IP del VPS), el puerto 80 sigue bloqueado en algún
  firewall intermedio, o el proxy naranja de Cloudflare sigue activo sobre ese registro.

  No combines este modo con el modo Cloudflare por defecto del `.env` (ambos quieren
  publicar 80/443) — usa uno de los dos según el despliegue.

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

El contenedor `zabbix-agent2` viene activo por defecto, en la misma red interna que el resto.
Todas las plantillas que usamos en esta sección (Nginx, PHP-FPM, MySQL) son de **comprobación
pasiva** — el server se conecta al agente, no al revés — así que en principio no necesitarías
nada de modo activo. Pero la imagen oficial, en cuanto le pasas `ZBX_SERVER_HOST` (que ya viene
puesto en `docker-compose.yml`), configura el agente para **los dos modos a la vez**: además de
`Server=zabbix-server` (pasivo), pone automáticamente `ServerActive=zabbix-server:10051`
(activo) — es un efecto del propio entrypoint de la imagen, no algo que este repo pida a
propósito. Por eso el agente igual intenta registrarse activamente contra el server aunque no lo
uses para nada de lo de aquí, y sin un host que coincida verás igualmente en el log de
`zabbix-server` el ruido de `cannot process heartbeat from host "zabbix-agent": host not found`.

Zabbix también trae de fábrica un host precreado llamado **"Zabbix server"**, con la plantilla
"Linux by Zabbix agent" ya adjunta y su interfaz de agente apuntando a `127.0.0.1:10050` — es
decir, al propio contenedor `zabbix-server`, donde **no corre ningún agente** (el agente vive
aparte, en `zabbix-agent2`). Tal cual viene, ese host nunca va a reportar nada y sólo genera
errores de conexión en el log (`item ... failed: first network error`). Hay que reconfigurarlo —
no crear uno nuevo, se reutiliza el mismo:

1. **Data collection → Hosts → "Zabbix server"** → pestaña **Host**: cambia el campo *Host
   name* de `Zabbix server` a `${COMPOSE_PROJECT_NAME:-zabbix}-agent` (con los defaults de
   `.env`, literalmente `zabbix-agent`) — debe coincidir exacto con el `Hostname` que trae
   configurado el contenedor (variable `ZBX_HOSTNAME` en `docker-compose.yml`). No es necesario
   para que las comprobaciones pasivas de abajo funcionen (esas dependen sólo del paso 2), pero
   sin esto verás indefinidamente el mensaje de "host not found" de arriba en el log — el
   agente sigue intentando el registro activo igual, esté o no ese host bien configurado. El
   *Visible name* lo puedes dejar como quieras (p.ej. "Zabbix server").
2. Pestaña **Interfaces**: edita la interfaz tipo *Agent* — cambia la IP `127.0.0.1` por DNS
   name `zabbix-agent2`, puerto `10050`, y marca **Connect to: DNS** (no IP: el contenedor no
   tiene una IP fija dentro de `zabbix-net`, pero su nombre sí resuelve vía el DNS interno de
   Docker). Con esto las comprobaciones pasivas (Nginx, PHP-FPM, MySQL de abajo) ya llegan al
   contenedor correcto.
3. Pestaña **Templates**: quita **"Linux by Zabbix agent"** — como `zabbix-agent2` corre en su
   propio contenedor, esos ítems miden el contenedor del agente (unos pocos MB de RAM, un
   proceso), no el VPS real, datos que no aportan nada (para monitorizar el VPS de verdad, ver
   la siguiente sección). Deja **"Zabbix server health"** (ya viene adjunta; son ítems internos
   que evalúa el propio server, no pasan por el agente) y añade, en el mismo host:

- **Nginx** (plantilla **"Nginx by Zabbix agent"**), macros:
  - `{$NGINX.STUB_STATUS.HOST}` = `zabbix-web`
  - `{$NGINX.STUB_STATUS.PORT}` = `8080`
  - `{$NGINX.STUB_STATUS.PATH}` = `nginx-status` *(la imagen usa `/nginx-status`, no el
    `/basic_status` que trae la plantilla por defecto)*
- **PHP-FPM** (misma plantilla host, **"PHP-FPM by Zabbix agent"**), macros:
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
- **"Linux by Zabbix agent active"** (ojo: la variante *active*, no "Linux by Zabbix agent" a
  secas — esa es la pasiva, y este agente sólo hace checks activos). Con esta sí obtienes las
  métricas reales del VPS (CPU, memoria, disco, red), no las del contenedor.
- **"Docker by Zabbix agent 2"**: usa el plugin nativo de Docker de agent2 (lee
  `/var/run/docker.sock` vía el parámetro `Plugins.Docker.Endpoint` de `zabbix_agent2.conf` —
  por defecto ya es `unix:///var/run/docker.sock`, normalmente no hace falta tocarlo). A
  diferencia de "Linux by Zabbix agent active", **esta plantilla no tiene variante activa** —
  sus ítems vienen configurados como pasivos de fábrica, lo que no combina con un agente
  puesto sólo en modo activo como el de aquí. Además usa **descubrimiento automático (LLD)**
  para listar contenedores/imágenes: los ítems de cada contenedor no existen de antemano, se
  crean sobre la marcha a partir de "prototipos de ítem" colgados de la regla de descubrimiento
  — por eso no basta con cambiar el tipo de los ítems ya creados (**Data collection → Hosts →
  Items**), hay que tocar también las reglas de descubrimiento y sus prototipos (**Data
  collection → Hosts → Discovery**), o cualquier contenedor nuevo que aparezca después seguirá
  creando sus ítems como pasivos. Lo más limpio es clonar la plantilla entera y editar el clon,
  no el host:
  1. **Data collection → Templates**, busca "Docker by Zabbix agent 2" → **Clone** (clonado
     completo: trae ítems, reglas de descubrimiento y prototipos). Renómbrala, p.ej. "Docker by
     Zabbix agent 2 (active)".
  2. Dentro del clon, pestaña **Items**: selecciona todos → **Mass update → Type → Zabbix agent
     (active)** (deja los de tipo *Dependent item* como están, esos no se conectan al agente
     directamente).
  3. Pestaña **Discovery**: entra a cada regla ("Containers discovery", "Images discovery") y
     cambia su propio *Type* a **Zabbix agent (active)**; dentro de cada una, en **Item
     prototypes**, repite el mass-update del paso 2 sobre los prototipos que no sean
     *Dependent item*.
  4. Enlaza este clon al host en vez de la plantilla original. Si en el futuro reimportas una
     versión más nueva de "Docker by Zabbix agent 2" desde Zabbix, tendrás que rehacer estos
     cambios sobre la nueva versión (clonar de nuevo o reaplicar a mano) — no hay forma de que
     Zabbix sincronice automáticamente un clon divergente con el original.
  - Alternativa (no recomendada, requiere abrir el host a los contenedores): usar la plantilla
    original tal cual (pasiva), añadiendo `Server=` en `zabbix_agent2.conf` del host y
    exponiendo su puerto 10050 para que `zabbix-server` pueda conectarse — vuelve a la
    exposición que esta sección evita a propósito.
  - **Acceso al socket**: el proceso del agente necesita permiso de lectura sobre
    `/var/run/docker.sock` (normalmente propiedad de `root:docker`). Si lo instalaste como
    paquete nativo, añade el usuario `zabbix` al grupo `docker` (`sudo usermod -aG docker
    zabbix` y reinicia el servicio `zabbix-agent2`). Si lo corres como contenedor aparte con
    `network_mode: host`, monta el socket (`-v /var/run/docker.sock:/var/run/docker.sock:ro`)
    y añade el grupo `docker` del host al contenedor (`--group-add` con el GID de `docker` en
    el host, o corre el contenedor como root si prefieres simplicidad sobre mínimo privilegio).

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
