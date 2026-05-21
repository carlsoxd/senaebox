#!/bin/bash
# SenaeBox AppRun — entry point del AppImage
#
# Cuando el usuario ejecuta SenaeBox-X.Y.Z-x86_64.AppImage:
#   1. AppImage se monta como squashfs en /tmp/.mount_SenaeXXXX
#   2. $APPDIR apunta a ese mount
#   3. Este script se invoca con los args del usuario
#   4. Configuramos env vars para que SenaeBox use los binarios bundled
#   5. Exec launch.sh (resto del flujo idéntico al desarrollo)

set -euo pipefail

# Detectar mount de AppImage. $APPDIR lo setea el runtime de AppImage.
APPDIR="${APPDIR:-$(dirname "$(readlink -f "$0")")}"
SENAE_ROOT="$APPDIR/opt/senaebox"

# =============================================================================
# 1. Validaciones de host (cosas que el AppImage NO puede traer)
# =============================================================================

_die() {
    if command -v zenity &>/dev/null; then
        zenity --error --title="SenaeBox" --width=460 --no-markup --text="$1" 2>/dev/null
    fi
    echo "ERROR: $1" >&2
    exit 1
}

# Bubblewrap DEBE estar en el host (SUID root). No se puede bundlear.
if ! command -v bwrap &>/dev/null; then
    _die "SenaeBox requiere 'bubblewrap' instalado en el sistema.\n\nFedora/RHEL:  sudo dnf install bubblewrap\nUbuntu/Debian: sudo apt install bubblewrap"
fi

# =============================================================================
# 2. Configurar env vars para que SenaeBox use los binarios del AppImage
# =============================================================================

# Wine-ge bundled: wine_env.sh detecta SENAEBOX_WINE como primer source
export SENAEBOX_WINE="$SENAE_ROOT/wine-runner/bin/wine"

# IMPORTANTE: apprun_2 pone DECENAS de $APPDIR/... en el PATH (vía AppRun.env),
# incluyendo $APPDIR/bin con bash bundled. Esos binarios tienen ELF interpreters
# RELATIVOS (lib64/ld-linux-x86-64.so.2) que solo el AppRun ELF sabe resolver
# vía libapprun_hooks LD_PRELOAD; cualquier fork+exec normal posterior falla con
# "no se puede ejecutar". Por eso, cuando launch.sh hace `bash setup_first_run.sh`,
# el bash bundled crashea sin output al stderr.
#
# Solución: filtrar $APPDIR/... del PATH excepto las rutas que SÍ queremos
# bundled (mitm-venv: Python + mitmproxy; usr/bin del AppDir: tools host-safe).
_path_clean=""
IFS=':' read -ra _path_parts <<< "$PATH"
for _p in "${_path_parts[@]}"; do
    case "$_p" in
        "$APPDIR/opt/senaebox/mitm-venv/bin") _path_clean+="$_p:" ;;
        "$APPDIR"*) ;;  # descartar el resto de $APPDIR/...
        *) _path_clean+="$_p:" ;;
    esac
done
export PATH="${_path_clean%:}"
unset _path_parts _path_clean _p

# Wine-ge bundled: wine_env.sh detecta SENAEBOX_WINE como primer source
export SENAEBOX_WINE="$SENAE_ROOT/wine-runner/bin/wine"

# Libs bundled (mesa software, X11 i386, etc.) — el AppRun ya las preconfigura
# vía APPDIR_LIBRARY_PATH, pero las dejamos por completitud.
export LD_LIBRARY_PATH="$APPDIR/usr/lib/x86_64-linux-gnu:$APPDIR/usr/lib/i386-linux-gnu:${LD_LIBRARY_PATH:-}"

# =============================================================================
# 3. Primera ejecución: copiar SENAE Browser portable y wine-runner al HOME
#    si aún no están. El usuario los tendrá entonces en su $HOME para
#    instalaciones siguientes/desarrollo.
#
# Esto NO toca estado del usuario — solo siembra los binarios bundled si no
# existen. Si el usuario ya tiene su instalación previa, no se sobrescribe.
# =============================================================================

USER_STATE="$HOME/.local/share/senaebox"
USER_WINE_RUNNER="$USER_STATE/wine-runner"
USER_BROWSER_DIR="$USER_STATE/wine/drive_c/users/$(whoami)/Documents/SENAE browser"

# Wine runner: si el usuario no lo tiene, NO copiar (mejor usar el del AppImage
# vía SENAEBOX_WINE para evitar duplicar 940MB en el HOME del usuario).
# launch.sh respeta SENAEBOX_WINE como override.

# SENAE Browser portable: setup_first_run.sh verifica esta ruta. Si no existe
# (primer arranque del AppImage), copiar desde los binarios bundled.
if [ ! -f "$USER_BROWSER_DIR/SENAE_browser_portable.exe" ]; then
    mkdir -p "$USER_BROWSER_DIR"
    # Solo copiar contenidos, NO sobrescribir Data/ si existe parcialmente
    rsync -a --ignore-existing "$SENAE_ROOT/senae-browser-portable/" "$USER_BROWSER_DIR/" || \
        cp -rn "$SENAE_ROOT/senae-browser-portable/." "$USER_BROWSER_DIR/" 2>/dev/null || true
fi

# =============================================================================
# 4. Exec launch.sh con $REPO_DIR apuntando al SENAE_ROOT del AppImage
# =============================================================================

# launch.sh deriva REPO_DIR de su propia ubicación. Lo invocamos directamente
# desde el AppImage; resolverá scripts/, sandbox/, etc. desde ahí.
exec "$SENAE_ROOT/launch.sh" "$@"
