#!/bin/bash
# Crea y configura el prefijo Wine de 32 bits para SenaeBox.
# Ejecutar UNA SOLA VEZ antes de usar el SENAE Browser.
#
# En Fedora 44, Wine 8+ usa WoW64 y no soporta WINEARCH=win32.
# Este script detecta automáticamente una alternativa compatible (wine-ge o Bottles).
# Si no encuentra ninguna, imprime instrucciones para instalarla.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINEPREFIX_DIR="$HOME/.local/share/senaebox/wine"

echo "=== SenaeBox — Crear WINEPREFIX ==="
echo ""

# --- 1. Detectar Wine compatible ---

echo "[1/5] Buscando Wine compatible con prefijos de 32 bits..."
# wine_env.sh exporta WINE_BIN y falla con instrucciones si no hay wine compatible
source "$SCRIPT_DIR/wine_env.sh"
echo "  Wine: $WINE_BIN"
echo ""

# --- 2. Verificar winetricks ---

echo "[2/5] Verificando winetricks..."

if ! command -v winetricks &>/dev/null; then
    echo ""
    echo "ERROR: winetricks no está instalado."
    echo "  Instala con: sudo dnf install winetricks"
    exit 1
fi
echo "  winetricks: OK"

# --- 3. Crear WINEPREFIX ---

echo "[3/5] Creando WINEPREFIX de 32 bits..."
echo "  Ruta: $WINEPREFIX_DIR"

if [ -d "$WINEPREFIX_DIR" ]; then
    echo ""
    echo "  ADVERTENCIA: El directorio ya existe."
    read -rp "  ¿Recrearlo desde cero? Esto borrará todo el prefijo. [s/N]: " respuesta
    if [[ "$respuesta" =~ ^[sS]$ ]]; then
        rm -rf "$WINEPREFIX_DIR"
        echo "  Directorio eliminado."
    else
        echo "  Usando prefijo existente. Saltando creación."
        echo "  Continuando con la configuración..."
    fi
fi

mkdir -p "$WINEPREFIX_DIR"

# WINEARCH=win32 obliga un prefijo de 32 bits puro.
# Los plugins NPAPI (Flash, Java) son de 32 bits y fallan en prefijos WoW64/64-bit.
echo "  Inicializando prefijo Win32 (puede tardar un momento)..."
WINEDEBUG=-all WINEARCH=win32 WINEPREFIX="$WINEPREFIX_DIR" \
    "$WINE_BIN" wineboot --init 2>/dev/null
echo "  Prefijo creado."

# --- 4. Aislar el WINEPREFIX del sistema de archivos real ---

echo "[4/5] Rompiendo enlaces simbólicos al sistema de archivos real..."
echo ""
echo "  Wine crea automáticamente symlinks dentro del prefijo que apuntan"
echo "  a tus carpetas reales (Documents, Desktop, Downloads, etc.)."
echo "  Cualquier proceso dentro del prefijo puede leer y escribir esas carpetas."
echo "  Se reemplazan por directorios vacíos reales para aislar el sandbox."
echo ""

# realpath resuelve ~ y variables para comparación exacta de rutas
PREFIX_REAL=$(realpath "$WINEPREFIX_DIR")
COUNT=0

# -print0 / read -d '' maneja correctamente nombres con espacios
while IFS= read -r -d '' symlink; do
    # Ruta canónica completa del destino del symlink
    target=$(readlink -f "$symlink" 2>/dev/null || true)

    # Si el destino resuelto cae fuera del WINEPREFIX, es una fuga al sistema real
    if [[ -n "$target" && "$target" != "$PREFIX_REAL"* ]]; then
        rm "$symlink"
        mkdir -p "$symlink"
        COUNT=$((COUNT + 1))
        echo "  [aislado] ${symlink#"$PREFIX_REAL/"} -> $target"
    fi
done < <(find "$WINEPREFIX_DIR" -type l -print0 2>/dev/null)

if [[ "$COUNT" -eq 0 ]]; then
    echo "  No se encontraron enlaces simbólicos que apunten fuera del prefijo."
else
    echo ""
    echo "  $COUNT enlace(s) reemplazado(s) por carpetas vacías aisladas."
fi

# --- 5. Configurar Wine ---

echo ""
echo "[5/5] Configurando Wine (puede tardar varios minutos)..."
echo "  Se descargarán e instalarán componentes de Windows."
echo ""

# winetricks necesita saber qué wine usar cuando no es el del sistema
WINE="$WINE_BIN"
export WINE

# Configurar como Windows 7 (requerido por el SENAE Browser)
echo "  Aplicando perfil Windows 7..."
WINEARCH=win32 WINEPREFIX="$WINEPREFIX_DIR" winetricks -q win7
echo "  Windows 7: OK"

# Instalar MSVC 2013 runtime (requerido por las DLLs del browser)
echo "  Instalando vcrun2013 (MSVC 2013 runtime)..."
WINEARCH=win32 WINEPREFIX="$WINEPREFIX_DIR" winetricks -q vcrun2013
echo "  vcrun2013: OK"

echo ""
echo "=== WINEPREFIX listo y aislado ==="
echo ""
echo "  Ruta  : $WINEPREFIX_DIR"
echo "  Wine  : $WINE_BIN"
echo ""
echo "Siguiente paso:"
echo "  bash scripts/install_java.sh /ruta/a/jre715.exe"
