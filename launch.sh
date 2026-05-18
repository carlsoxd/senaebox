#!/bin/bash
# SenaeBox — Launcher principal
#
# Se ejecuta desde el ícono del escritorio (Terminal=false).
# No imprime nada en terminal — todo va a logs y diálogos gráficos.
#
# Flujo:
#   1. Verificar dependencias mínimas
#   2. Evitar instancias múltiples (lock file)
#   3. Primera vez → setup silencioso con barra de progreso
#   4. Verificar/instalar certificado CA del proxy en Firefox
#   5. Arrancar proxy TLS en segundo plano
#   6. Abrir el browser en sandbox (bloqueante)
#   7. Al cerrar: detener proxy, limpiar lock

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Rutas ---
STATE_DIR="$HOME/.local/share/senaebox"
LOG_DIR="$STATE_DIR/logs"
LOCK_FILE="/tmp/senaebox.lock"
PROXY_SOCK="/tmp/senaebox-proxy.sock"
PROXY_PID_FILE="/tmp/senaebox-proxy.pid"
SETUP_MARKER="$STATE_DIR/.setup_complete"
PROFILE_DIR="$STATE_DIR/wine/drive_c/users/$(whoami)/Documents/SENAE browser/Data/profile"

mkdir -p "$LOG_DIR"
LAUNCHER_LOG="$LOG_DIR/launcher_$(date +%Y%m%d_%H%M%S).log"

# Redirigir toda salida al log desde este punto. Sin terminal.
exec > >(tee -a "$LAUNCHER_LOG") 2>&1

echo "=== SenaeBox launcher $(date) ==="

# =============================================================================
# Funciones de diálogo
# =============================================================================

_dialog() {
    local mode="$1"; shift
    if command -v zenity &>/dev/null; then
        zenity "$mode" --title="SENAE Browser" --width=460 --no-markup "$@" 2>/dev/null
    else
        notify-send --urgency=critical "SENAE Browser" "$*" 2>/dev/null || true
    fi
}

show_error() {
    echo "ERROR: $*"
    _dialog --error --text="$*"
}

show_info() {
    echo "INFO: $*"
    _dialog --info --text="$*"
}

# =============================================================================
# Verificar dependencias mínimas
# =============================================================================

MISSING_DEPS=()
command -v zenity    &>/dev/null || MISSING_DEPS+=("zenity        →  sudo dnf install zenity")
command -v bwrap     &>/dev/null || MISSING_DEPS+=("bubblewrap    →  sudo dnf install bubblewrap")
command -v mitmdump  &>/dev/null || MISSING_DEPS+=("mitmproxy     →  pip install mitmproxy")
command -v socat     &>/dev/null || MISSING_DEPS+=("socat         →  sudo dnf install socat")
# Nota: podman NO es requirement de runtime. Se usa solo durante setup_first_run.sh
# para parchear cert8.db con la CA generada para este usuario. Si el usuario no lo
# tiene instalado, setup lo instala vía pkexec, lo usa, y lo desinstala al terminar.

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    MSG="El SENAE Browser no puede abrirse porque faltan programas necesarios:\n"
    for dep in "${MISSING_DEPS[@]}"; do
        MSG="$MSG\n  •  $dep"
    done
    MSG="$MSG\n\nInstálalos y vuelve a intentar.\nDetalles en: $LAUNCHER_LOG"
    show_error "$MSG"
    exit 1
fi

# =============================================================================
# Evitar instancias múltiples
# =============================================================================

if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        show_error "El SENAE Browser ya está abierto.\n\nSi el ícono no responde, espera unos segundos y vuelve a intentar."
        exit 1
    fi
    echo "Eliminando lock stale de PID $OLD_PID"
    rm -f "$LOCK_FILE"
fi

echo $$ > "$LOCK_FILE"

# =============================================================================
# Funciones de ciclo de vida del proxy
# =============================================================================

_stop_proxy() {
    # 1. Matar procesos del PID file (sesión actual)
    if [ -f "$PROXY_PID_FILE" ]; then
        echo "Deteniendo proxy..."
        read -r _MPID _SPID < "$PROXY_PID_FILE" 2>/dev/null || true
        kill "$_MPID" "$_SPID" 2>/dev/null || true
        rm -f "$PROXY_PID_FILE"
    fi

    # 2. Matar cualquier mitmdump que ocupe el puerto 8081, sin importar de dónde venga.
    #    Bug: si una sesión anterior crasheó sin limpiar, el nuevo mitmdump falla con
    #    EADDRINUSE y run_proxy.sh devuelve 0 de todas formas → el browser usa el
    #    zombie con caché TLS vencida → "Send failed - Login Error" en el 2do módulo Flash.
    local _stale_pid
    _stale_pid=$(ss -tlnpH 2>/dev/null | awk '/127\.0\.0\.1:8081/{match($0,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | head -1)
    if [ -n "$_stale_pid" ]; then
        echo "Matando mitmdump zombie (PID $_stale_pid, puerto 8081)..."
        kill "$_stale_pid" 2>/dev/null || true
        # Esperar a que libere el puerto (máx 2 s)
        local _wait=0
        while [ "$_wait" -lt 4 ] && ss -tlnpH 2>/dev/null | grep -q '127\.0\.0\.1:8081'; do
            sleep 0.5
            _wait=$((_wait + 1))
        done
    fi

    rm -f "$PROXY_SOCK"
    echo "Proxy detenido."
}

# =============================================================================
# Mapeo de C:\users\luis\Downloads → ~/SenaeBox/Descargas
#
# Wine registra por default FOLDERID_Downloads = C:\users\luis\Downloads.
# Pero ese directorio es DENTRO del wineprefix — no es visible para el host.
#
# Históricamente el user.js usaba browser.download.dir = "Z:\\home\\luis\\..."
# (drive Z = / por convención Wine), pero create_wineprefix.sh borra el
# symlink z: → / como parte del aislamiento de symlinks fugados. Resultado:
# Z:\ apunta a directorio vacío → Firefox cae al default C:\users\luis\Downloads
# → descargas terminan en el wineprefix, no en ~/SenaeBox/Descargas.
#
# Solución: convertir el directorio Downloads del wineprefix en symlink hacia
# /home/luis/SenaeBox/Descargas. El bind mount del sandbox monta esa ruta como
# el directorio real del host. Wine sigue el symlink → escribe en bind →
# aparece en ~/SenaeBox/Descargas del host. Sin tocar drive letters ni user.js.
#
# Idempotente: si el symlink ya está correcto, no hace nada. Si es directorio
# vacío o symlink incorrecto, lo recrea. Si tiene archivos (descargas previas
# perdidas en el prefix), los mueve a la carpeta compartida antes de reemplazar.
# =============================================================================

_ensure_downloads_symlink() {
    local prefix_downloads="$STATE_DIR/wine/drive_c/users/$(whoami)/Downloads"
    local shared_downloads="$HOME/SenaeBox/Descargas"

    mkdir -p "$shared_downloads"

    # Caso 1: ya es symlink correcto → no hacer nada
    if [ -L "$prefix_downloads" ] && [ "$(readlink "$prefix_downloads")" = "$shared_downloads" ]; then
        return 0
    fi

    # Caso 2: es directorio (vacío o con archivos perdidos de sesiones anteriores)
    if [ -d "$prefix_downloads" ] && [ ! -L "$prefix_downloads" ]; then
        # Rescatar archivos perdidos antes de reemplazar
        local rescued=0
        while IFS= read -r -d '' f; do
            mv -n "$f" "$shared_downloads/" 2>/dev/null && rescued=$((rescued + 1))
        done < <(find "$prefix_downloads" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
        [ "$rescued" -gt 0 ] && echo "Rescatados $rescued archivos de descargas previas al wineprefix → ~/SenaeBox/Descargas/"
        rmdir "$prefix_downloads" 2>/dev/null || rm -rf "$prefix_downloads"
    fi

    # Caso 3: es symlink incorrecto → eliminar
    [ -L "$prefix_downloads" ] && rm -f "$prefix_downloads"

    # Crear el symlink correcto
    ln -s "$shared_downloads" "$prefix_downloads"
    echo "Downloads del wineprefix → ~/SenaeBox/Descargas (symlink creado)"
}

# =============================================================================
# Limpieza periódica de archivos *.Identifier (Wine emula Zone.Identifier ADS)
#
# Windows marca archivos descargados con el flujo NTFS alternativo
# Zone.Identifier (Mark of the Web). Wine sobre ext4 generalmente usa el xattr
# `user.zone.identifier` (no archivo visible), pero en algunas combinaciones
# crea archivos sufijados como `file.pdf:Zone.Identifier` o `file.pdf.Identifier`.
#
# Cleanup en background: cada 5 segundos elimina cualquier archivo sufijado
# con :Zone.Identifier o .Identifier en la carpeta de descargas. También
# elimina xattrs user.zone.identifier para que el archivo aparezca "limpio".
# El loop muere cuando launch.sh termina (trap EXIT mata el PID).
# =============================================================================

_zone_identifier_cleanup_loop() {
    local downloads="$HOME/SenaeBox/Descargas"
    while [ -f "$LOCK_FILE" ]; do
        # Archivos visibles (caso Wine sin xattr o filesystem sin soporte)
        find "$downloads" -maxdepth 2 \
            \( -name '*:Zone.Identifier' -o -name '*.Identifier' -o -name 'Zone.Identifier' \) \
            -delete 2>/dev/null
        # xattrs (caso Wine con xattr support en ext4)
        if command -v setfattr &>/dev/null; then
            find "$downloads" -maxdepth 2 -type f -print0 2>/dev/null | \
                xargs -0 -r setfattr -x user.zone.identifier 2>/dev/null
        fi
        sleep 5
    done
}

_ZONE_CLEANUP_PID=""

# Al salir por cualquier motivo: detener proxy, watcher, quitar lock
_shutdown() {
    [ -n "$_ZONE_CLEANUP_PID" ] && kill "$_ZONE_CLEANUP_PID" 2>/dev/null || true
    _stop_proxy
    rm -f "$LOCK_FILE"
}
trap '_shutdown' EXIT INT TERM

# =============================================================================
# Primera vez: setup silencioso con barra de progreso
# =============================================================================

if [ ! -f "$SETUP_MARKER" ]; then
    echo "Primera ejecución — iniciando setup..."

    # setup_first_run.sh escribe "N" (porcentaje) y "# Texto" (etiqueta) a stdout
    # para zenity --progress, y mensajes de log a stderr.
    bash "$REPO_DIR/scripts/setup_first_run.sh" 2>>"$LAUNCHER_LOG" \
        | zenity --progress \
                 --title="SENAE Browser — Configuración inicial" \
                 --text="Preparando el SENAE Browser por primera vez...\n\nEsto puede tardar varios minutos." \
                 --percentage=0 --auto-close --no-cancel --width=480 2>/dev/null

    # PIPESTATUS[0] = exit code de setup_first_run.sh
    SETUP_EXIT="${PIPESTATUS[0]}"

    if [ "$SETUP_EXIT" -ne 0 ]; then
        show_error "La configuración inicial falló.\n\nRevisa el log para más detalles:\n$LAUNCHER_LOG"
        exit 1
    fi

    touch "$SETUP_MARKER"
    echo "Setup completado."
fi

# =============================================================================
# Crear carpetas compartidas si no existen
# =============================================================================

mkdir -p "$HOME/SenaeBox/Descargas" "$HOME/SenaeBox/Documentos"

# cert8.db (NSS DB con la CA confiada) se genera UNA VEZ en setup_first_run.sh.
# Los launches posteriores no tocan certificados: el cert8.db ya existe en el
# profile, mitmproxy usa la CA del usuario en ~/.local/share/senaebox/ca/, y
# Firefox confía en la CA porque está en cert8.db. Sin dependencia de podman.

# =============================================================================
# Arrancar proxy TLS en segundo plano
# =============================================================================

# Limpiar restos de sesiones anteriores que crasharon
_stop_proxy
rm -f "$PROXY_SOCK"

echo "Arrancando proxy TLS..."
if ! bash "$REPO_DIR/proxy/run_proxy.sh" --bg >> "$LAUNCHER_LOG" 2>&1; then
    show_error "No se pudo arrancar el proxy de seguridad.\n\nDetalles en: $LAUNCHER_LOG"
    exit 1
fi

# Esperar socket del proxy (máx 8 s)
for i in $(seq 1 16); do
    sleep 0.5
    [ -S "$PROXY_SOCK" ] && break
    if [ "$i" -eq 16 ]; then
        show_error "El proxy tardó demasiado en arrancar.\n\nDetalles en: $LAUNCHER_LOG"
        exit 1
    fi
done
echo "Proxy listo."

# =============================================================================
# Aplicar configuración de registro Wine (DPI, virtual desktop, X11 Driver)
#
# Este paso DEBE correr fuera del sandbox y matar el wineserver para que
# el wineserver del sandbox arranque con el registro ya correcto. Es lo que
# hace que el chrome de Firefox se escale a 125% (LogPixels=120 leído por
# GetDeviceCaps en el primer arranque del wineserver).
#
# El script es idempotente: si todo ya está aplicado solo lee los .reg
# (no spawnea wine) y sale en ~0.1 s.
# =============================================================================

bash "$REPO_DIR/scripts/fix_wine_registry.sh" >> "$LAUNCHER_LOG" 2>&1 \
    || echo "ADVERTENCIA: fix_wine_registry.sh falló — continuando con valores actuales del registro."

# Aplicar zoom 125% inicial para dominios de Ecuapass (idempotente vía marker).
# Sale en <100ms si ya se aplicó. Wine no debe estar corriendo (la DB de Firefox
# se locked si el browser está abierto), así que va después de fix_wine_registry.sh
# que mata el wineserver.
bash "$REPO_DIR/scripts/configure_zoom.sh" >> "$LAUNCHER_LOG" 2>&1 \
    || echo "ADVERTENCIA: configure_zoom.sh falló — el zoom se puede ajustar manualmente con Ctrl+."

# =============================================================================
# Invalidar startupCache si chrome/ tiene archivos más nuevos
#
# Firefox 41 cachea TODO el contenido de chrome/ (userChrome.css, userContent.css,
# XUL, JS) en <profile>/startupCache/startupCache.4.little. La invalidación
# natural de este cache solo ocurre cuando cambia el BuildID de Firefox
# (comparado con compatibility.ini LastVersion). NUNCA se invalida por cambios
# en archivos del profile.
#
# Esto significa que cualquier edición de chrome/userChrome.css o
# chrome/userContent.css por parte de SenaeBox queda ignorada hasta que el
# cache se invalide manualmente. Síntomas observados:
#   - userChrome.css que oculta "Pantalla completa" sin efecto visible
#   - userContent.css con zoom @-moz-document sin efecto en las páginas
#
# Fix: borrar startupCache si DETECTAMOS que algún archivo en chrome/ es más
# nuevo que el cache. Firefox lo regenera en el próximo arranque (~2-3 s extra
# una sola vez), garantizando que nuestros archivos se procesen.
# =============================================================================

_invalidate_startup_cache_if_needed() {
    local cache_dir="$PROFILE_DIR/startupCache"
    local chrome_dir="$PROFILE_DIR/chrome"
    local cache_file="$cache_dir/startupCache.4.little"

    [ -d "$chrome_dir" ] || return 0

    if [ ! -f "$cache_file" ]; then
        # No hay cache aún (primer arranque o ya invalidado) — nada que hacer
        return 0
    fi

    # ¿Algún archivo en chrome/ es más nuevo que el cache?
    if [ -n "$(find "$chrome_dir" -type f -newer "$cache_file" -print -quit 2>/dev/null)" ]; then
        echo "chrome/ modificado tras último cache — invalidando startupCache para forzar recarga."
        rm -rf "$cache_dir"
    fi
}

_invalidate_startup_cache_if_needed

# Asegurar que Downloads del wineprefix apunte a ~/SenaeBox/Descargas
_ensure_downloads_symlink

# Arrancar el watcher de Zone.Identifier en background (muere con el trap EXIT)
_zone_identifier_cleanup_loop &
_ZONE_CLEANUP_PID=$!

# =============================================================================
# Auto-parchar xulstore.json: tamaño de ventana corrupto por ciclo Wine/Mutter
#
# Bug irreparable a nivel sandbox:
#   1. Usuario click "Restaurar" del WM sobre ventana maximizada
#   2. Mutter manda ConfigureRequest con "tamaño anterior" — pero la ventana
#      nació maximized, Mutter no tiene previous size guardado
#   3. Wine devuelve WM_GETMINMAXINFO con defaults de Windows (~112×27)
#   4. Mutter manda WM_SIZE con ~80×25 (peor por margen de decoración)
#   5. Firefox acepta y guarda ese tamaño en xulstore.json
#   6. Siguiente arranque: ventana abre tiny porque xulstore tiene 80×25
#
# Mitigaciones intentadas que NO funcionaron:
#   - browser.window.width/height en user.js → no overridea xulstore
#   - userChrome.css min-width: 800px → solo afecta layout XUL interno, no la
#     ventana del WM que ya colapsó
#   - Pre-parchar xulstore una sola vez → Firefox lo re-corrompe en la siguiente
#     sesión donde el usuario interactúa con el botón restaurar
#
# Esta función: parchar xulstore en CADA launch antes de que Firefox arranque,
# si main-window tiene tamaño irrazonable. Forzar sizemode=normal para que
# Mutter aprenda el tamaño natural primero (si el usuario maximiza después,
# Mutter recordará 1280×720 como previous → restaurar funciona correctamente).
# =============================================================================

_fix_xulstore_window_size() {
    local xulstore="$PROFILE_DIR/xulstore.json"
    [ -f "$xulstore" ] || return 0

    python3 - "$xulstore" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    print(f"xulstore no parseable: {e}", file=sys.stderr)
    sys.exit(0)

key = "chrome://browser/content/browser.xul"
mw = data.get(key, {}).get("main-window")
if not mw:
    sys.exit(0)

try:
    width  = int(float(mw.get("width",  "1280")))
    height = int(float(mw.get("height", "720")))
except (ValueError, TypeError):
    width, height = 0, 0

# Sano = al menos 800×600. Cualquier cosa menor es resultado del bug
# Wine/Mutter de WM_GETMINMAXINFO.
if width >= 800 and height >= 600:
    sys.exit(0)

mw["width"]  = "1280"
mw["height"] = "720"
mw["screenX"] = "320"
mw["screenY"] = "180"
# Forzar sizemode=normal: si arranca maximized, Mutter nunca aprende el
# tamaño natural y el bug se reproduce. Normal → usuario maximiza manualmente
# si quiere, Mutter recuerda 1280×720 para restaurar correctamente.
mw["sizemode"] = "normal"

data[key]["main-window"] = mw
with open(path, "w") as f:
    json.dump(data, f, separators=(",", ":"))

print(f"xulstore reparado: tamaño anterior {width}×{height} → 1280×720 (sizemode=normal)", file=sys.stderr)
PYEOF
}

_fix_xulstore_window_size

# =============================================================================
# Abrir el browser (bloqueante)
# =============================================================================

echo "Abriendo SENAE Browser..."
bash "$REPO_DIR/sandbox/launch_sandbox.sh" >> "$LAUNCHER_LOG" 2>&1
BROWSER_EXIT=$?
echo "Browser cerrado (código: $BROWSER_EXIT)."

# Post-cierre: el cert8.db ya fue generado durante setup_first_run.sh con
# la CA del usuario. No hay nada que sincronizar aquí en runtime — esto
# eliminaría la dependencia de podman en arranques posteriores. Si en algún
# escenario raro Firefox borra/regenera su cert8.db, el usuario verá errores
# de cert y deberá re-correr setup (borrar $SETUP_MARKER y re-lanzar).

# El trap EXIT detiene el proxy y elimina el lock.
echo "Sesión terminada."
