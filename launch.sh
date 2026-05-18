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
CA_FP_MARKER="$STATE_DIR/.ca_fingerprint"
MITM_CERT="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
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
command -v podman    &>/dev/null || MISSING_DEPS+=("podman        →  sudo dnf install podman")
command -v mitmdump  &>/dev/null || MISSING_DEPS+=("mitmproxy     →  pip install mitmproxy")
command -v socat     &>/dev/null || MISSING_DEPS+=("socat         →  sudo dnf install socat")

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

# Al salir por cualquier motivo: detener proxy y quitar lock
trap '_stop_proxy; rm -f "$LOCK_FILE"' EXIT INT TERM

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

# =============================================================================
# Verificar e instalar certificado CA del proxy en Firefox
#
# Compara el SHA-256 del cert actual con el último instalado (marker file).
# Sin match → instalar vía Podman (solo cuando es necesario, no en cada sesión).
# =============================================================================

_install_ca_if_needed() {
    [ -f "$MITM_CERT" ]              || { echo "CA cert no existe aún."; return 0; }
    [ -f "$PROFILE_DIR/cert8.db" ]   || { echo "cert8.db no existe aún (primer arranque de Firefox)."; return 0; }

    CURRENT_FP=$(openssl x509 -in "$MITM_CERT" -noout -fingerprint -sha256 2>/dev/null || echo "")
    STORED_FP=$(cat "$CA_FP_MARKER" 2>/dev/null || echo "")

    if [ "$CURRENT_FP" = "$STORED_FP" ] && [ -n "$CURRENT_FP" ]; then
        echo "Certificado CA vigente — sin cambios."
        return 0
    fi

    echo "Instalando certificado CA en Firefox..."

    # Indicador visual mientras Podman trabaja (se cierra solo en 120 s máximo)
    zenity --progress --pulsate --no-cancel \
           --title="SENAE Browser" \
           --text="Instalando certificado de seguridad en Firefox...\n\nLa primera vez descarga una imagen (~75 MB). Espera un momento." \
           --width=460 2>/dev/null &
    ZENITY_WAIT_PID=$!

    bash "$REPO_DIR/scripts/install_proxy_cert.sh" >> "$LAUNCHER_LOG" 2>&1
    CERT_EXIT=$?

    kill "$ZENITY_WAIT_PID" 2>/dev/null || true

    if [ "$CERT_EXIT" -eq 0 ]; then
        echo "$CURRENT_FP" > "$CA_FP_MARKER"
        echo "Certificado CA instalado."
    else
        show_error "No se pudo instalar el certificado de seguridad.\n\nEl browser se abrirá, pero Ecuapass puede mostrar un error de certificado.\n\nDetalles en: $LAUNCHER_LOG"
    fi
}

_install_ca_if_needed

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

# =============================================================================
# Post-cierre: instalar CA si cert8.db acaba de aparecer (primer arranque real)
# =============================================================================

if [ -f "$PROFILE_DIR/cert8.db" ] && [ ! -f "$CA_FP_MARKER" ]; then
    echo "cert8.db nuevo detectado — instalando certificado CA..."
    _install_ca_if_needed
    if [ -f "$CA_FP_MARKER" ]; then
        show_info "Configuración completa.\n\nVuelve a abrir el SENAE Browser.\nEcuapass cargará sin errores de certificado."
    fi
fi

# El trap EXIT detiene el proxy y elimina el lock.
echo "Sesión terminada."
