#!/bin/bash
# Instala JRE 7 Update 15 dentro del prefijo Wine de SenaeBox.
#
# Uso:
#   bash scripts/install_java.sh /ruta/a/jre715.exe
#   bash scripts/install_java.sh          (busca jre715.exe en el directorio actual)
#
# IMPORTANTE: El script verifica el SHA-256 antes de instalar.
# Configura EXPECTED_SHA256 con el hash del instalador oficial que tienes.
# Para obtener el hash de tu archivo: sha256sum jre715.exe

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINEPREFIX_DIR="$HOME/.local/share/senaebox/wine"

# SHA-256 esperado del instalador oficial jre715.exe.
# Deja vacío para que el script te muestre el hash del archivo
# y te pida confirmación manual antes de continuar.
#
# Una vez que verifiques que el hash es correcto, pégalo aquí para
# que futuras ejecuciones sean automáticas y seguras.
EXPECTED_SHA256=""

echo "=== SenaeBox — Instalar Java JRE 7u15 ==="
echo ""

# --- 0. Detectar Wine compatible ---

echo "[0/3] Buscando Wine compatible..."
source "$SCRIPT_DIR/wine_env.sh"
echo "  Wine: $WINE_BIN"
echo ""

# --- 1. Localizar jre715.exe ---

echo "[1/3] Localizando jre715.exe..."

JRE_EXE="${1:-jre715.exe}"

if [ ! -f "$JRE_EXE" ]; then
    echo ""
    echo "ERROR: No se encontró el instalador."
    echo "  Buscado en: $JRE_EXE"
    echo ""
    echo "  Uso: bash scripts/install_java.sh /ruta/a/jre715.exe"
    echo ""
    echo "  El archivo jre715.exe está en la carpeta Installers/"
    echo "  dentro de la carpeta SENAE browser que tienes en Windows."
    exit 1
fi

echo "  Archivo: $JRE_EXE"

# --- 2. Verificación SHA-256 ---

echo "[2/3] Verificando integridad del instalador..."

ACTUAL_SHA256=$(sha256sum "$JRE_EXE" | awk '{print $1}')
echo "  SHA-256: $ACTUAL_SHA256"

if [ -n "$EXPECTED_SHA256" ]; then
    # Verificación automática contra hash conocido
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        echo ""
        echo "ERROR CRÍTICO: El hash SHA-256 no coincide."
        echo "  Esperado: $EXPECTED_SHA256"
        echo "  Obtenido: $ACTUAL_SHA256"
        echo ""
        echo "  El archivo puede estar corrupto o haber sido modificado."
        echo "  NO se instalará por seguridad."
        exit 1
    fi
    echo "  Hash verificado: OK"
else
    echo ""
    echo "  AVISO: No hay hash de referencia configurado en este script."
    echo "  Verifica manualmente que el hash de arriba corresponde al"
    echo "  instalador oficial de Oracle JRE 7 Update 15."
    echo ""
    echo "  Una vez verificado, guarda el hash en la variable EXPECTED_SHA256"
    echo "  dentro de este script para que futuras instalaciones sean automáticas."
    echo ""
    read -rp "  ¿Continuar con la instalación de todas formas? [s/N]: " respuesta
    if [[ ! "$respuesta" =~ ^[sS]$ ]]; then
        echo "Instalación cancelada."
        exit 0
    fi
fi

# --- Verificar WINEPREFIX ---

if [ ! -d "$WINEPREFIX_DIR" ]; then
    echo ""
    echo "ERROR: WINEPREFIX no encontrado en: $WINEPREFIX_DIR"
    echo "  Ejecuta primero: bash scripts/create_wineprefix.sh"
    exit 1
fi

# --- 3. Instalar JRE 7u15 ---

echo "[3/3] Instalando JRE 7u15 en Wine..."
echo "  Esto puede tardar varios minutos. Puede aparecer una ventana de instalación."
echo ""

# /s = instalación silenciosa (sin ventanas de configuración)
WINEARCH=win32 WINEPREFIX="$WINEPREFIX_DIR" "$WINE_BIN" "$JRE_EXE" /s

echo "  Instalación completada."

# --- Verificar npjp2.dll ---

echo ""
echo "Verificando plugin Java (npjp2.dll)..."

NPJP2_ENCONTRADO=$(find "$WINEPREFIX_DIR/drive_c" -iname "npjp2.dll" 2>/dev/null | head -1 || true)

if [ -n "$NPJP2_ENCONTRADO" ]; then
    echo "  npjp2.dll encontrado en:"
    echo "  $NPJP2_ENCONTRADO"
    echo ""
    echo "=== Java instalado correctamente ==="
else
    echo ""
    echo "  ADVERTENCIA: npjp2.dll no fue encontrado."
    echo "  La instalación puede no haber completado correctamente."
    echo "  Busca errores relacionados con Java en el log de Wine."
fi

echo ""
echo "Siguiente paso: bash scripts/setup_pki.sh"
