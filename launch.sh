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
