#!/bin/bash
# Genera un certificado autofirmado (snake-oil) + dhparam para el frontend HTTPS de Zabbix,
# si no existen ya. Pensado para exponerse detrás de Cloudflare / cloudflared (que ya se
# encargan del TLS público), donde un certificado autofirmado en el origen es suficiente.
#
# Uso:
#   ./scripts/generate-certs.sh                  # genera sólo si faltan
#   ./scripts/generate-certs.sh --force           # regenera aunque ya existan
#   ./scripts/generate-certs.sh --dhparam-only    # sólo dhparam.pem, no toca ssl.crt/ssl.key
#   CERT_CN=zabbix.midominio.com ./scripts/generate-certs.sh
#
# Si en vez de esto prefieres un certificado real (comprado, o un Origin Certificate de
# Cloudflare — ver sección HTTPS del README), coloca tu ssl.crt / ssl.key a mano en
# data/nginx/ssl/ y usa --dhparam-only para generar sólo el dhparam.pem (Cloudflare no lo
# provee). Para Let's Encrypt automático ver docker-compose.override.yml.example.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_DIR="${SCRIPT_DIR}/../data/nginx/ssl"
CERT_CN="${CERT_CN:-zabbix.local}"
FORCE=0
DHPARAM_ONLY=0

case "${1:-}" in
    --force) FORCE=1 ;;
    --dhparam-only) DHPARAM_ONLY=1 ;;
esac

mkdir -p "${SSL_DIR}"

if [[ "${DHPARAM_ONLY}" -eq 1 ]]; then
    echo "Modo --dhparam-only: no se toca ssl.crt/ssl.key."
elif [[ -f "${SSL_DIR}/ssl.crt" && -f "${SSL_DIR}/ssl.key" && "${FORCE}" -eq 0 ]]; then
    echo "Ya existen ${SSL_DIR}/ssl.crt y ssl.key, no se regeneran (usa --force para forzar)."
else
    echo "Generando certificado autofirmado (CN=${CERT_CN})..."
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "${SSL_DIR}/ssl.key" -out "${SSL_DIR}/ssl.crt" \
        -subj "/CN=${CERT_CN}"
fi

if [[ -f "${SSL_DIR}/dhparam.pem" && "${FORCE}" -eq 0 ]]; then
    echo "Ya existe ${SSL_DIR}/dhparam.pem, no se regenera (usa --force para forzar)."
else
    echo "Generando dhparam (2048 bits, puede tardar un poco)..."
    openssl dhparam -out "${SSL_DIR}/dhparam.pem" 2048
fi

echo "Listo. Certificados en ${SSL_DIR}"
