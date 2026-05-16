#!/bin/bash
# Lanza el SENAE Browser dentro de Wine.
#
# FASE 2 — Sin sandbox ni proxy TLS.
# Esta versión es solo para verificar que Wine + Flash + Java funcionan.
# NO uses esta versión para trámites reales con datos sensibles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINEPREFIX_DIR="$HOME/.local/share/senaebox/wine"
LOG_DIR="$HOME/.local/share/senaebox/logs"
WINE_USER=$(whoami)

SENAE_EXE_WIN="C:\\users\\$WINE_USER\\Documents\\SENAE browser\\SENAE_browser_portable.exe"
SENAE_EXE_LINUX="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/SENAE_browser_portable.exe"

echo "=== SenaeBox — Fase 2 (Wine, sin sandbox) ==="
echo ""

# --- Detectar Wine compatible ---

echo "Buscando Wine compatible..."
source "$SCRIPT_DIR/scripts/wine_env.sh"
echo "  Wine: $WINE_BIN"
echo ""

# --- Verificaciones previas ---

# 1. Verificar WINEPREFIX
if [ ! -d "$WINEPREFIX_DIR" ]; then
    echo "ERROR: WINEPREFIX no configurado."
    echo "  Ejecuta: bash scripts/create_wineprefix.sh"
    exit 1
fi

# 2. Verificar que el SENAE Browser está copiado
if [ ! -f "$SENAE_EXE_LINUX" ]; then
    echo "ERROR: SENAE_browser_portable.exe no encontrado."
    echo ""
    echo "  Ruta esperada:"
    echo "  $SENAE_EXE_LINUX"
    echo ""
    echo "  Copia la carpeta 'SENAE browser' desde Windows a esa ubicación."
    echo "  La carpeta completa está en Documents/SENAE browser/ en tu PC Windows."
    exit 1
fi

# --- Preparar log ---

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/wine_$(date +%Y%m%d_%H%M%S).log"

{
    echo "SenaeBox — Log de Wine"
    echo "Fecha   : $(date)"
    echo "Usuario : $WINE_USER"
    echo "Exe     : $SENAE_EXE_LINUX"
    echo "---"
} > "$LOG_FILE"

# --- Lanzar el browser ---

echo "  Ejecutable : $SENAE_EXE_LINUX"
echo "  Log Wine   : $LOG_FILE"
echo ""
echo "  ADVERTENCIA: Fase 2 — sin sandbox ni proxy TLS."
echo "  Solo para probar que el browser arranca. No uses para trámites reales."
echo ""
echo "Iniciando SENAE Browser..."
echo ""

# stdout de Wine va a la terminal para que Luis vea mensajes en tiempo real.
# stderr va al log para análisis posterior si algo falla.
#
# LIBGL_ALWAYS_SOFTWARE=1: fuerza renderizado por CPU (LLVMpipe) en lugar de GPU.
# Necesario porque Wine no implementa dxgi_resource_GetSharedHandle, y Firefox 41
# crashea con STATUS_BREAKPOINT cuando el compositor DXGI falla (xul.dll:0185AD7E).
LIBGL_ALWAYS_SOFTWARE=1 \
WINEARCH=win32 WINEPREFIX="$WINEPREFIX_DIR" \
    "$WINE_BIN" "$SENAE_EXE_WIN" \
    2>>"$LOG_FILE"

EXIT_CODE=$?

echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
    echo "Browser cerrado normalmente (código: 0)."
else
    echo "Browser cerrado con código de error: $EXIT_CODE"
    echo ""
    echo "Revisa el log para más detalles:"
    echo "  $LOG_FILE"
    echo ""
    echo "Pistas comunes en el log:"
    echo "  'err:module' — DLL faltante"
    echo "  'err:ole'    — problema con COM/DCOM"
    echo "  'fixme:heap' — puede ignorarse"
fi
