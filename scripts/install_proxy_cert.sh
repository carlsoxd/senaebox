#!/bin/bash
# SenaeBox — Instalar certificado CA de mitmproxy en Firefox 41
#
# Firefox 41 usa NSS con formato DBM (cert8.db / key3.db / secmod.db).
# certutil necesita el prefijo "dbm:" para abrir este formato.
# Sin el prefijo, certutil crearía un cert9.db vacío y NO tocaría cert8.db.
#
# Solo es necesario ejecutar este script una vez (o cada vez que mitmproxy
# regenere su CA, lo que ocurre si se borra ~/.mitmproxy/).
#
# Requisitos:
#   sudo dnf install nss-tools        (certutil)
#   bash proxy/run_proxy.sh           (genera ~/.mitmproxy/mitmproxy-ca-cert.pem)

set -euo pipefail

WINE_USER=$(whoami)
PROFILE_DIR="$HOME/.local/share/senaebox/wine/drive_c/users/$WINE_USER/Documents/SENAE browser/Data/profile"
MITM_CERT="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
CERT_NICKNAME="mitmproxy CA (SenaeBox)"

echo "=== SenaeBox — Instalar CA de mitmproxy en Firefox 41 ==="
echo ""

# --- Verificar dependencias ---
if ! command -v certutil &>/dev/null; then
    echo "ERROR: certutil no está instalado."
    echo "  sudo dnf install nss-tools"
    exit 1
fi

# --- Verificar que mitmproxy generó su CA ---
if [ ! -f "$MITM_CERT" ]; then
    echo "ERROR: Certificado CA no encontrado en: $MITM_CERT"
    echo ""
    echo "  Inicia el proxy al menos una vez para que mitmproxy genere el certificado:"
    echo "    bash proxy/run_proxy.sh"
    echo ""
    echo "  Luego vuelve a ejecutar este script."
    exit 1
fi

# --- Verificar perfil de Firefox ---
if [ ! -f "$PROFILE_DIR/cert8.db" ]; then
    echo "ERROR: cert8.db no encontrado."
    echo "  Ruta esperada: $PROFILE_DIR/cert8.db"
    echo ""
    echo "  El perfil de Firefox no está inicializado. Lanza el browser una vez primero:"
    echo "    bash sandbox/launch_sandbox.sh  (con --share-net aún activo)"
    exit 1
fi

echo "  Perfil : $PROFILE_DIR"
echo "  Cert CA: $MITM_CERT"
echo ""

# Mostrar datos del certificado para verificación visual
if command -v openssl &>/dev/null; then
    echo "Certificado a instalar:"
    openssl x509 -in "$MITM_CERT" -noout -subject -issuer -dates 2>/dev/null || true
    echo ""
fi

# --- Verificar si ya está instalado ---
if certutil -d "dbm:$PROFILE_DIR" -L 2>/dev/null | grep -qF "$CERT_NICKNAME"; then
    echo "El certificado '$CERT_NICKNAME' ya está instalado."
    echo ""
    echo "Para reinstalarlo, elimínalo primero:"
    echo "  certutil -d \"dbm:$PROFILE_DIR\" -D -n \"$CERT_NICKNAME\""
    exit 0
fi

# --- Instalar el certificado ---
# -d dbm:<dir> : directorio NSS con formato DBM (cert8.db)
# -A           : añadir certificado (modo "add")
# -n <name>    : nickname visible en el gestor de certificados de Firefox
# -t "CT,,"    : trust flags — C=trusted CA para SSL, T=trusted para email
#                (primer campo vacío = no confianza para firma de objetos)
certutil \
    -d "dbm:$PROFILE_DIR" \
    -A \
    -n "$CERT_NICKNAME" \
    -t "CT,," \
    -i "$MITM_CERT"

echo "Certificado instalado."
echo ""

# --- Verificar instalación ---
echo "Verificando:"
if certutil -d "dbm:$PROFILE_DIR" -L 2>/dev/null | grep -F "$CERT_NICKNAME"; then
    echo ""
    echo "OK — Firefox 41 confiará en los certificados firmados por mitmproxy."
else
    echo "ERROR: El certificado no aparece en la lista tras instalarlo."
    echo "  Verifica manualmente:"
    echo "    certutil -d \"dbm:$PROFILE_DIR\" -L"
    exit 1
fi
