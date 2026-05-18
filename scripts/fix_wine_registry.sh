#!/bin/bash
# SenaeBox — Espejo de DPI del sistema hacia el registro de Wine
#
# Filosofía: Wine no decide nada sobre DPI. Simplemente refleja el DPI que
# XWayland ya reporta al resto de apps X11. Si el sistema dice 96, Wine usa 96.
# Si dice 120, Wine usa 120. Sin cálculos, sin compensaciones, sin asumir nada
# sobre cómo Mutter/XWayland manejan internamente la escala fraccional.
#
# Esto es crítico para distribución porque cualquier escala que el usuario
# configure produce el resultado correcto sin código por caso.
#
# Adicionalmente limpia configuración que rompe el arranque:
#   - HKCU\Software\Wine\Explorer\Desktop — virtual desktop hace que Wine
#     arranque explorer.exe que falla con nodrv_CreateWindow dentro del sandbox
#   - HKCU\Software\Wine\X11 Driver — settings custom innecesarias
#
# IMPORTANTE: se ejecuta FUERA del sandbox y mata el wineserver para que el
# wineserver del sandbox arranque leyendo el registro actualizado.
#
# Uso:
#   bash scripts/fix_wine_registry.sh
#
# Override de DPI (si la detección falla o para forzar un valor):
#   SENAEBOX_DPI=120 bash scripts/fix_wine_registry.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINEPREFIX_DIR="$HOME/.local/share/senaebox/wine"
USER_REG="$WINEPREFIX_DIR/user.reg"
SYSTEM_REG="$WINEPREFIX_DIR/system.reg"

# ---------------------------------------------------------------------------
# Leer el DPI que XWayland reporta al sistema
#
# Fuentes consultadas en orden:
#   1. SENAEBOX_DPI (override env var)
#   2. xrdb -query Xft.dpi (lo que las apps X11/GTK usan — más confiable)
#   3. xdpyinfo resolution (DPI calculado por el X server)
#   4. Default 96 (DPI estándar de Windows)
# ---------------------------------------------------------------------------

_detect_system_dpi() {
    if [ -n "${SENAEBOX_DPI:-}" ]; then
        echo "$SENAEBOX_DPI"
        return
    fi

    local dpi=""

    # xrdb -query: "Xft.dpi:    120"
    if command -v xrdb &>/dev/null; then
        dpi=$(xrdb -query 2>/dev/null | awk '/^Xft\.dpi:/ {print $2; exit}')
    fi

    # xdpyinfo: "  resolution:    96x96 dots per inch"
    if [ -z "$dpi" ] && command -v xdpyinfo &>/dev/null; then
        dpi=$(xdpyinfo 2>/dev/null | awk '/resolution:/ {split($2, a, "x"); print a[1]; exit}')
    fi

    # Default
    [ -z "$dpi" ] && dpi="96"

    # Quitar decimales si los hay (xrdb a veces da float)
    dpi="${dpi%.*}"

    # Validar que sea entero positivo razonable; si no, default 96
    if ! [[ "$dpi" =~ ^[0-9]+$ ]] || [ "$dpi" -lt 1 ]; then
        dpi="96"
    fi

    echo "$dpi"
}

LOGPIXELS=$(_detect_system_dpi)
LOGPIXELS_HEX=$(printf '%08x' "$LOGPIXELS")

# ---------------------------------------------------------------------------
# Detección idempotente: ¿hay que hacer algo?
# ---------------------------------------------------------------------------

_needs_fix() {
    grep -A6 '\[System\\\\CurrentControlSet\\\\Hardware Profiles\\\\Current\\\\Software\\\\Fonts\]' \
        "$SYSTEM_REG" 2>/dev/null | grep -q "\"LogPixels\"=dword:$LOGPIXELS_HEX" || return 0

    grep -A20 '\[Control Panel\\\\Desktop\]' "$USER_REG" 2>/dev/null \
        | grep -q "\"LogPixels\"=dword:$LOGPIXELS_HEX" || return 0

    grep -q '\[Software\\\\Wine\\\\Explorer\]' "$USER_REG" 2>/dev/null && return 0

    grep -q '\[Software\\\\Wine\\\\X11 Driver\]' "$USER_REG" 2>/dev/null && return 0

    return 1
}

echo "[fix_wine_registry] DPI del sistema: $LOGPIXELS (espejado a Wine LogPixels)"

if ! _needs_fix; then
    echo "[fix_wine_registry] Registro Wine ya configurado — sin cambios."
    exit 0
fi

echo "[fix_wine_registry] Aplicando LogPixels=$LOGPIXELS y limpiando virtual desktop / X11 Driver..."

source "$SCRIPT_DIR/wine_env.sh"
WINESERVER_BIN="${WINE_BIN%wine}wineserver"

export WINEPREFIX="$WINEPREFIX_DIR"
export WINEARCH=win32
export WINEDEBUG=-all

# ---------------------------------------------------------------------------
# 1. Espejar el DPI del sistema en HKCU y HKLM
# ---------------------------------------------------------------------------

"$WINE_BIN" reg add 'HKCU\Control Panel\Desktop' \
    /v LogPixels /t REG_DWORD /d "$LOGPIXELS" /f 2>/dev/null

"$WINE_BIN" reg add 'HKLM\System\CurrentControlSet\Hardware Profiles\Current\Software\Fonts' \
    /v LogPixels /t REG_DWORD /d "$LOGPIXELS" /f 2>/dev/null

# ---------------------------------------------------------------------------
# 2. ELIMINAR virtual desktop (causa "explorer process failed to start")
# ---------------------------------------------------------------------------

"$WINE_BIN" reg delete 'HKCU\Software\Wine\Explorer' /v Desktop /f 2>/dev/null || true
"$WINE_BIN" reg delete 'HKCU\Software\Wine\Explorer\Desktops' /f      2>/dev/null || true
"$WINE_BIN" reg delete 'HKCU\Software\Wine\Explorer' /f               2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. ELIMINAR X11 Driver custom settings
# ---------------------------------------------------------------------------

"$WINE_BIN" reg delete 'HKCU\Software\Wine\X11 Driver' /f 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Reinicio limpio del wineserver
# ---------------------------------------------------------------------------

"$WINESERVER_BIN" -k 2>/dev/null || true
sleep 0.5

echo "[fix_wine_registry] Configuración aplicada y wineserver reiniciado."
