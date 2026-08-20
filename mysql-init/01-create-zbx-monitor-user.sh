#!/bin/bash
# Ejecutado automáticamente por la imagen oficial de MySQL (docker-entrypoint-initdb.d)
# SÓLO en el primer arranque, cuando /var/lib/mysql está vacío.
#
# Crea el usuario "zbx_monitor" con los privilegios que pide la plantilla oficial de Zabbix
# "MySQL by Zabbix agent 2" (ver templates/db/mysql_agent2/README.md en zabbix/zabbix), para
# poder monitorizar este mismo MySQL desde el zabbix-agent2 incluido en el stack sin usar la
# cuenta root.
#
# Usa $MYSQL_ROOT_PASSWORD, que en este punto del arranque siempre está disponible en el
# entorno — tanto si la fijaste tú en .env como si la generó al azar MYSQL_RANDOM_ROOT_PASSWORD
# (el entrypoint de la imagen la exporta igual en ambos casos antes de correr este script).
#
# Si el volumen de datos ya existía (este script no llegó a correr), crea el usuario a mano.
# Necesitas la contraseña root: si la fijaste tú, es la de tu .env; si era aleatoria, sólo
# quedó una vez en "docker compose logs mysql-server" (busca "GENERATED ROOT PASSWORD") — si
# no la guardaste, fija una nueva primero con MYSQL_ROOT_PASSWORD en .env y
# "docker compose up -d mysql-server" para poder entrar como root.
#   docker compose exec mysql-server mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
# y pega el bloque SQL de abajo.

set -euo pipefail

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE USER IF NOT EXISTS 'zbx_monitor'@'%' IDENTIFIED BY '${MYSQL_MONITOR_PASSWORD}';
    GRANT REPLICATION CLIENT, PROCESS, SHOW DATABASES, SHOW VIEW ON *.* TO 'zbx_monitor'@'%';
    FLUSH PRIVILEGES;
EOSQL
