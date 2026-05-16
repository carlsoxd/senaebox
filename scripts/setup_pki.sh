#!/bin/bash
# Copia los JARs de firma PKI del Ecuapass a todas las rutas correctas
# dentro del prefijo Wine.
#
# Equivalente Linux del script copy_pki_dev_7_ecuapass_portal.bat oficial.
# El applet Java de firma busca estos archivos en:
#   %AppData%\LocalLow\sg\openews\_[dominio]_[puerto]\

set -euo pipefail

WINEPREFIX_DIR="$HOME/.local/share/senaebox/wine"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_SRC_DIR="$SCRIPT_DIR/../pki"

# Los 4 JARs del sistema de firma electrónica del Ecuapass
JARS=(
    "sgapplet.jar"
    "ewscommon.jar"
    "xmlsecurity_client_api-1.0.jar"
    "xmlsecurity_applet_file-1.0.jar"
)

# Todos los dominios del portal Ecuapass donde debe haber JARs.
# Extraído del copy_pki_dev_7_ecuapass_portal.bat oficial.
DOMINIOS=(
    # Producción — portal principal
    "_portalinterno.aduana.gob.ec_80_"
    "_portalinterno.aduana.gob.ec_443_"
    "_portal.aduana.gob.ec_80_"
    "_portal.aduana.gob.ec_443_"
    "_ecuapass.aduana.gob.ec_80_"
    "_ecuapass.aduana.gob.ec_443_"
    # Test / QA
    "_portaltest.aduana.gob.ec_80_"
    "_portaltest.aduana.gob.ec_443_"
    "_ecuapasstest.aduana.gob.ec_80_"
    "_ecuapasstest.aduana.gob.ec_443_"
    # Desarrollo
    "_portaldev.aduana.gob.ec_80_"
    "_portaldev.aduana.gob.ec_443_"
    "_ecuapassdev.aduana.gob.ec_80_"
    "_ecuapassdev.aduana.gob.ec_443_"
    # Integración
    "_portalint.aduana.gob.ec_80_"
    "_portalint.aduana.gob.ec_443_"
    "_ecuapassint.aduana.gob.ec_80_"
    "_ecuapassint.aduana.gob.ec_443_"
)

echo "=== SenaeBox — Configurar JARs PKI ==="
echo ""

# --- 1. Verificaciones previas ---

echo "[1/3] Verificando requisitos..."

if [ ! -d "$WINEPREFIX_DIR" ]; then
    echo ""
    echo "ERROR: WINEPREFIX no encontrado en: $WINEPREFIX_DIR"
    echo "  Ejecuta primero: bash scripts/create_wineprefix.sh"
    exit 1
fi
echo "  WINEPREFIX: OK"

if [ ! -d "$PKI_SRC_DIR" ]; then
    echo ""
    echo "ERROR: Directorio pki/ no encontrado en: $PKI_SRC_DIR"
    echo "  Los JARs deben estar en la carpeta pki/ del repositorio."
    exit 1
fi
echo "  Directorio pki/: OK"

# Verificar que los 4 JARs están presentes
FALTANTES=0
for jar in "${JARS[@]}"; do
    if [ -f "$PKI_SRC_DIR/$jar" ]; then
        echo "  OK: $jar"
    else
        echo "  FALTANTE: $jar"
        FALTANTES=$((FALTANTES + 1))
    fi
done

if [ "$FALTANTES" -gt 0 ]; then
    echo ""
    echo "ERROR: Faltan $FALTANTES JARs en $PKI_SRC_DIR"
    echo "  Copia los JARs desde la carpeta pki/ de tu instalación Windows."
    exit 1
fi

# --- 2. Detectar ruta de usuario dentro del WINEPREFIX ---

echo "[2/3] Detectando rutas Wine..."

WINE_USER=$(whoami)
APPDATA_BASE="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/AppData/LocalLow/sg/openews"

echo "  Usuario: $WINE_USER"
echo "  Ruta AppData: $APPDATA_BASE"

# --- 3. Copiar JARs a cada dominio ---

echo "[3/3] Copiando JARs a ${#DOMINIOS[@]} dominios..."
echo ""

TOTAL=${#DOMINIOS[@]}
CONTADOR=0
TOTAL_ARCHIVOS=0

for dominio in "${DOMINIOS[@]}"; do
    DEST_DIR="$APPDATA_BASE/$dominio"
    mkdir -p "$DEST_DIR"

    for jar in "${JARS[@]}"; do
        cp "$PKI_SRC_DIR/$jar" "$DEST_DIR/$jar"
        TOTAL_ARCHIVOS=$((TOTAL_ARCHIVOS + 1))
    done

    CONTADOR=$((CONTADOR + 1))
    echo "  [$CONTADOR/$TOTAL] $dominio"
done

echo ""
echo "=== JARs PKI instalados correctamente ==="
echo ""
echo "  Dominios configurados : $TOTAL"
echo "  JARs por dominio      : ${#JARS[@]}"
echo "  Total archivos copiados: $TOTAL_ARCHIVOS"
echo ""
echo "Siguiente paso:"
echo "  Copia la carpeta 'SENAE browser' desde Windows a:"
echo "  $WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/"
echo ""
echo "  Luego ejecuta: bash launch.sh"
