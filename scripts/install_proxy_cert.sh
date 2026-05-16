#!/bin/bash
# SenaeBox — Instalar certificado CA de mitmproxy en Firefox 41
#
# Firefox 41 usa NSS 3.20, que tiene DBM (cert8.db) como formato por defecto.
# El problema en Fedora 44: NSS 3.123 eliminó el backend DBM, así que el
# certutil del sistema no puede escribir en cert8.db (SEC_ERROR_LEGACY_DATABASE).
#
# Comportamiento de Firefox 41 con el perfil:
#   - Si cert8.db existe     → usa DBM (cert8.db), ignora cert9.db
#   - Si cert8.db no existe  → crea cert8.db vacío en el primer arranque
#
# Solución: usar un contenedor Podman con AlmaLinux 8 (NSS 3.67, con soporte
# DBM) para instalar el certificado en cert8.db. Si el perfil no tiene cert8.db
# todavía (Firefox no ha arrancado), se instala en cert9.db y Firefox lo
# sobreescribe al arrancar — ver el mensaje de advertencia abajo.
#
# Solo es necesario ejecutar este script una vez por instalación de mitmproxy.
# Si mitmproxy regenera su CA (al borrar ~/.mitmproxy/), volver a ejecutarlo.
#
# Requisitos:
#   podman                    (incluido en Fedora por defecto)
#   bash proxy/run_proxy.sh   (genera ~/.mitmproxy/mitmproxy-ca-cert.pem)
#
# Flujo recomendado (primera vez):
#   1. bash proxy/run_proxy.sh --bg        (genera la CA)
#   2. bash sandbox/launch_sandbox.sh      (Firefox crea cert8.db)
#   3. Cerrar Firefox
#   4. bash scripts/install_proxy_cert.sh  (instala CA en cert8.db via Podman)
#   5. bash sandbox/launch_sandbox.sh      (Firefox confía en mitmproxy CA)

set -euo pipefail

WINE_USER=$(whoami)
PROFILE_DIR="$HOME/.local/share/senaebox/wine/drive_c/users/$WINE_USER/Documents/SENAE browser/Data/profile"
MITM_CERT="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
CERT_NICKNAME="mitmproxy CA (SenaeBox)"

# Imagen de contenedor con certutil antiguo compatible con DBM.
# AlmaLinux 8 (equivalente RHEL 8) usa NSS ~3.67, que mantiene soporte DBM.
# Alternativa si falla: fedora:37 (NSS ~3.83, también con soporte DBM).
PODMAN_IMAGE="almalinux:8"

echo "=== SenaeBox — Instalar CA de mitmproxy en Firefox 41 ==="
echo ""

# --- Verificar dependencias ---
if ! command -v podman &>/dev/null; then
    echo "ERROR: podman no está instalado."
    echo "  sudo dnf install podman"
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

echo "  Perfil : $PROFILE_DIR"
echo "  Cert CA: $MITM_CERT"
echo ""

# Mostrar datos del certificado para verificación visual
if command -v openssl &>/dev/null; then
    echo "Certificado a instalar:"
    openssl x509 -in "$MITM_CERT" -noout -subject -issuer -dates 2>/dev/null || true
    echo ""
fi

# --- Detectar estado del perfil ---

HAS_CERT8=false
HAS_CERT9=false
[ -f "$PROFILE_DIR/cert8.db" ] && HAS_CERT8=true
[ -f "$PROFILE_DIR/cert9.db" ] && HAS_CERT9=true

if ! $HAS_CERT8 && ! $HAS_CERT9; then
    echo "ERROR: No se encontró ninguna base de datos NSS en el perfil."
    echo "  Ruta esperada: $PROFILE_DIR"
    echo ""
    echo "  Firefox 41 debe haber arrancado al menos una vez para crear cert8.db."
    echo "  Flujo correcto:"
    echo "    1. bash proxy/run_proxy.sh --bg"
    echo "    2. bash sandbox/launch_sandbox.sh   (Firefox crea cert8.db; habrá error de cert)"
    echo "    3. Cerrar Firefox"
    echo "    4. bash scripts/install_proxy_cert.sh"
    exit 1
fi

# =============================================================================
# RAMA A: cert8.db existe — Firefox 41 ya arrancó y creó su base de datos DBM.
#         Usamos Podman con AlmaLinux 8 (NSS ~3.67) para escribir en cert8.db.
# =============================================================================
if $HAS_CERT8; then
    echo "Formato detectado: DBM (cert8.db) — usando Podman con $PODMAN_IMAGE"
    echo ""

    # Verificar si el certificado ya está instalado (en cert8.db)
    # certutil moderno no puede leerlo; ejecutamos la verificación también dentro del contenedor
    ALREADY_INSTALLED=$(podman run --rm \
        -v "$PROFILE_DIR:/profile:Z" \
        "$PODMAN_IMAGE" \
        bash -c "dnf install -y nss-tools -q &>/dev/null && \
                 certutil -d dbm:/profile -L 2>/dev/null | grep -cF '$CERT_NICKNAME' || true" \
        2>/dev/null || echo "0")

    if [ "$ALREADY_INSTALLED" -gt 0 ] 2>/dev/null; then
        echo "El certificado '$CERT_NICKNAME' ya está instalado en cert8.db."
        echo ""
        echo "Para reinstalarlo, elimínalo primero:"
        echo "  podman run --rm -v \"$PROFILE_DIR:/profile:Z\" $PODMAN_IMAGE \\"
        echo "    bash -c \"dnf install -y nss-tools -q && certutil -d dbm:/profile -D -n '$CERT_NICKNAME'\""
        exit 0
    fi

    echo "Instalando CA en cert8.db via Podman..."
    echo "(Primera vez: Podman descargará la imagen $PODMAN_IMAGE ~75 MB)"
    echo ""

    podman run --rm \
        -v "$PROFILE_DIR:/profile:Z" \
        -v "$MITM_CERT:/mitmproxy-ca.pem:ro,Z" \
        "$PODMAN_IMAGE" \
        bash -c "
            set -e
            dnf install -y nss-tools -q &>/dev/null

            echo 'Certificados antes de instalar:'
            certutil -d dbm:/profile -L 2>/dev/null || true
            echo ''

            certutil \
                -d dbm:/profile \
                -A \
                -n '$CERT_NICKNAME' \
                -t 'CT,,' \
                -i /mitmproxy-ca.pem

            echo 'Certificados tras instalar:'
            certutil -d dbm:/profile -L 2>/dev/null
        "

    echo ""
    echo "Verificando desde el host (certutil moderno)..."
    # El certutil moderno no puede leer DBM, pero Podman sí puede verificar
    VERIFY=$(podman run --rm \
        -v "$PROFILE_DIR:/profile:Z" \
        "$PODMAN_IMAGE" \
        bash -c "dnf install -y nss-tools -q &>/dev/null && \
                 certutil -d dbm:/profile -L 2>/dev/null | grep -cF '$CERT_NICKNAME' || true" \
        2>/dev/null || echo "0")

    if [ "$VERIFY" -gt 0 ] 2>/dev/null; then
        echo ""
        echo "OK — Certificado '$CERT_NICKNAME' instalado en cert8.db."
        echo "     Firefox 41 confiará en los certificados firmados por mitmproxy."
    else
        echo "ERROR: El certificado no aparece en cert8.db tras intentar instalarlo."
        echo "  Verifica manualmente:"
        echo "  podman run --rm -v \"$PROFILE_DIR:/profile:Z\" $PODMAN_IMAGE \\"
        echo "    bash -c \"dnf install -y nss-tools -q && certutil -d dbm:/profile -L\""
        exit 1
    fi

# =============================================================================
# RAMA B: solo cert9.db — Firefox 41 aún no ha arrancado.
#         Instalamos en cert9.db con certutil moderno, pero ADVERTIMOS que
#         Firefox 41 creará cert8.db vacío al arrancar, ignorando cert9.db.
# =============================================================================
else
    echo "Formato detectado: SQL (cert9.db) — Firefox 41 aún no ha arrancado."
    echo ""
    echo "ADVERTENCIA: Firefox 41 (NSS 3.20) crea cert8.db al primer arranque y lo"
    echo "  usa como base de datos principal, ignorando cert9.db. El certificado"
    echo "  instalado aquí quedará sin efecto."
    echo ""
    echo "  Flujo correcto para que el CA quede en cert8.db:"
    echo "    1. bash sandbox/launch_sandbox.sh   (Firefox crea cert8.db)"
    echo "    2. Cerrar Firefox (habrá error de cert — es esperado)"
    echo "    3. bash scripts/install_proxy_cert.sh  (este script)"
    echo ""
    echo "  ¿Continuar de todas formas e instalar en cert9.db? (s/N)"
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[sS]$ ]]; then
        echo "Abortado."
        exit 0
    fi

    if certutil -d "sql:$PROFILE_DIR" -L 2>/dev/null | grep -qF "$CERT_NICKNAME"; then
        echo "El certificado '$CERT_NICKNAME' ya está instalado en cert9.db."
        exit 0
    fi

    certutil \
        -d "sql:$PROFILE_DIR" \
        -A \
        -n "$CERT_NICKNAME" \
        -t "CT,," \
        -i "$MITM_CERT"

    echo "Certificado instalado en cert9.db (temporal hasta que Firefox arranque)."
fi

echo ""
echo "Siguiente paso:"
echo "  bash sandbox/launch_sandbox.sh"
