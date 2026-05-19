#!/bin/bash
# SenaeBox — Proxy TLS (Fase 4)
#
# Inicia mitmproxy + el puente socat que expone el proxy al sandbox.
#
# Flujo de tráfico:
#   Firefox (sandbox) → socat TCP 127.0.0.1:8080 → UNIX /tmp/senaebox-proxy.sock
#   socat UNIX → TCP 127.0.0.1:8081 → mitmproxy → Internet
#
# Este script corre FUERA del sandbox. El sandbox monta el socket Unix en su
# /tmp y no tiene acceso directo a la red del host (--unshare-net).
#
# Uso:
#   bash proxy/run_proxy.sh          # primer plano (Ctrl+C para detener)
#   bash proxy/run_proxy.sh --bg     # segundo plano, PID en /tmp/senaebox-proxy.pid
#
# Primera vez (generar CA local y poblar cert8.db de Firefox):
#   bash scripts/setup_first_run.sh

set -euo pipefail

# Directorio del repositorio (run_proxy.sh está en proxy/ dentro del repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PROXY_SOCK="/tmp/senaebox-proxy.sock"
MITM_HOST="127.0.0.1"
MITM_PORT=8081
BG_MODE=false
PID_FILE="/tmp/senaebox-proxy.pid"
STATE_DIR="${STATE_DIR:-$HOME/.local/share/senaebox}"
LOG_DIR="$STATE_DIR/logs"

# CA propia de SenaeBox (no la personal de mitmproxy en ~/.mitmproxy/).
# El directorio contiene mitmproxy-ca.pem (key + cert combinados) que mitmdump
# usa para firmar dinámicamente certificados leaf para cada dominio HTTPS.
# Generada por setup_first_run.sh con openssl (única por instalación, nunca
# distribuida en el repo). Permisos: 700 (dir), 600 (key), 644 (cert público).
SENAEBOX_CA_DIR="$STATE_DIR/ca"

[[ "${1:-}" == "--bg" ]] && BG_MODE=true

# Captura de flujos AMF: activar con SENAE_CAPTURE=1 bash launch.sh
# Guarda un archivo .mitm por sesión en el directorio de logs para
# inspección posterior con: python3 proxy/amf_inspect.py <archivo.mitm>
FLOW_ARGS=()
if [[ "${SENAE_CAPTURE:-0}" == "1" ]]; then
    mkdir -p "$LOG_DIR"
    FLOW_FILE="$LOG_DIR/flows_$(date +%Y%m%d_%H%M%S).mitm"
    FLOW_ARGS=(--save-stream-file "$FLOW_FILE")
    echo "Captura AMF habilitada → $FLOW_FILE"
fi

# --- Verificar dependencias ---
MISSING=()
command -v mitmdump &>/dev/null || MISSING+=("mitmdump (pip install mitmproxy)")
command -v socat    &>/dev/null || MISSING+=("socat    (sudo dnf install socat)")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: faltan dependencias:"
    printf '  %s\n' "${MISSING[@]}"
    exit 1
fi

# --- Cleanup al salir ---
MITM_PID=""
SOCAT_PID=""

cleanup() {
    echo ""
    echo "Deteniendo proxy SenaeBox..."
    [ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null || true
    [ -n "$MITM_PID" ] && kill "$MITM_PID"  2>/dev/null || true
    rm -f "$PROXY_SOCK" "$PID_FILE"
    echo "Proxy detenido."
}
trap cleanup EXIT INT TERM

# Limpiar socket anterior
rm -f "$PROXY_SOCK"

echo "=== SenaeBox — Proxy TLS (Fase 4) ==="
echo ""

# --- 1. Iniciar mitmproxy ---
# Modo proxy HTTP/HTTPS estándar (--mode regular es el default).
# Firefox lo configura como proxy explícito via user.js (network.proxy.type=1).
echo "Iniciando mitmproxy en $MITM_HOST:$MITM_PORT..."

# addon_blazeds.py: reinyecta jsessionid de BlazeDS en canales de polling.
# Corrige el "Login Error" intermitente por pérdida de afinidad de nodo
# en el cluster BlazeDS de Ecuapass. Ver proxy/addon_blazeds.py para detalles.
ADDON_ARGS=()
ADDON_PATH="$REPO_DIR/proxy/addon_blazeds.py"
if [ -f "$ADDON_PATH" ]; then
    ADDON_ARGS=(-s "$ADDON_PATH")
else
    echo "AVISO: addon_blazeds.py no encontrado en $ADDON_PATH"
fi

# --- Verificación de defaults TLS antes de arrancar mitmproxy ---
#
# Nota técnica importante: mitmproxy 12+ trae como default
#   tls_version_client_min: TLS1_2
#   tls_version_server_min: TLS1_2
# Esto es exactamente nuestra postura de hardening (rechazar SSL3/TLS1.0/1.1).
#
# Por qué NO usamos --set tls_version_*=TLS1_2 explícito:
#   Cuando esas opciones cambian (incluso reasignándolas al mismo valor por
#   defecto), mitmproxy llama _warn_unsupported_version() que itera sobre
#   TODAS las versiones TLS conocidas con set_min_proto_version(). OpenSSL 4.0+
#   rechaza protocolos viejos con error en vez de "no soportado silente",
#   causando crash al arranque (verificado en mitmproxy 12.2.3 + OpenSSL 4.0.0).
#
# En vez de eso, verificamos que los defaults sean lo que esperamos. Si una
# versión futura de mitmproxy baja los defaults, abortamos con error claro.
TLS_CLIENT_MIN=$(mitmdump --options 2>/dev/null | awk '/^tls_version_client_min:/ {print $2; exit}')
TLS_SERVER_MIN=$(mitmdump --options 2>/dev/null | awk '/^tls_version_server_min:/ {print $2; exit}')

_ge_tls12() {
    case "$1" in
        TLS1_2|TLS1_3) return 0 ;;
        *)             return 1 ;;
    esac
}

if ! _ge_tls12 "$TLS_CLIENT_MIN"; then
    echo "ERROR: mitmproxy default tls_version_client_min es '$TLS_CLIENT_MIN' (se requiere ≥TLS1_2)."
    echo "       Esta versión de mitmproxy no cumple con la postura de seguridad."
    echo "       Actualiza mitmproxy o reporta este issue: pip install --upgrade mitmproxy"
    exit 1
fi
if ! _ge_tls12 "$TLS_SERVER_MIN"; then
    echo "ERROR: mitmproxy default tls_version_server_min es '$TLS_SERVER_MIN' (se requiere ≥TLS1_2)."
    echo "       Mitmproxy aceptaría conexiones upstream con TLS antiguo. Abortando."
    exit 1
fi
echo "  TLS hardening: client_min=$TLS_CLIENT_MIN, server_min=$TLS_SERVER_MIN (defaults OK)"

# Verificar que la CA de SenaeBox esté instalada antes de arrancar.
if [ ! -f "$SENAEBOX_CA_DIR/mitmproxy-ca.pem" ]; then
    echo "ERROR: CA de SenaeBox no encontrada en $SENAEBOX_CA_DIR/"
    echo "       Ejecuta: bash scripts/setup_first_run.sh (genera la CA con openssl)"
    exit 1
fi

# --- Política de cero persistencia del tráfico interceptado ---
#
# Por defecto: stdout/stderr de mitmdump → /dev/null. Sin redirigir, los logs
# de cada request HTTPS (URL, host, status code, headers) terminan escritos en
# el launcher_*.log porque mitmdump (lanzado con &) hereda los FDs del padre
# (`bash run_proxy.sh --bg >> "$LAUNCHER_LOG"` desde launch.sh). Eso significa
# que cada visita a Ecuapass deja un registro permanente del tráfico en disk.
#
# La redirección explícita >/dev/null 2>&1 corta esa cadena: mitmdump ya no
# tiene FDs apuntando a archivos del host. Defense in depth con flow_detail=0
# (oculta path/método/status en consola) y termlog_verbosity=warn (no log de
# eventos de conexión normales).
#
# Modo captura (SENAE_CAPTURE=1): mantiene stdout heredado + save-stream-file
# para diagnóstico. Solo activar conscientemente cuando se necesite analizar.
MITM_ARGS=(
    --listen-host "$MITM_HOST"
    --listen-port "$MITM_PORT"
    --set stream_large_bodies=100k
    --set confdir="$SENAEBOX_CA_DIR"
    "${ADDON_ARGS[@]}"
    "${FLOW_ARGS[@]}"
)

if [[ "${SENAE_CAPTURE:-0}" == "1" ]]; then
    # Captura activa: ver todo en stdout + persistir flows
    mitmdump "${MITM_ARGS[@]}" &
else
    # Cero persistencia: silenciar consola + descartar FDs
    mitmdump "${MITM_ARGS[@]}" \
        --set flow_detail=0 \
        --set termlog_verbosity=warn \
        </dev/null >/dev/null 2>&1 &
fi
# confdir: directorio donde mitmproxy busca mitmproxy-ca.pem (key+cert) para
# firmar certs leaf. Apunta a la CA propia del usuario en ~/.local/share/
# senaebox/ca/ (generada en setup), NO a la CA personal de ~/.mitmproxy/.
MITM_PID=$!

# Esperar a que mitmproxy esté escuchando en el puerto.
# IMPORTANTE: verificar el puerto, no solo que el proceso exista.
# Si el puerto ya estaba en uso, mitmproxy termina con error ANTES de que
# el proceso desaparezca, por lo que kill -0 da falso positivo.
for i in $(seq 1 10); do
    sleep 0.5
    if ss -tlnpH 2>/dev/null | grep -q "${MITM_HOST}:${MITM_PORT}"; then
        break   # Puerto escuchando — mitmproxy listo
    fi
    if ! kill -0 "$MITM_PID" 2>/dev/null; then
        echo "ERROR: mitmproxy terminó antes de arrancar (¿puerto $MITM_PORT ya en uso?)."
        exit 1
    fi
    if [ "$i" -eq 10 ]; then
        echo "ERROR: mitmproxy no empezó a escuchar en ${MITM_HOST}:${MITM_PORT} después de 5 segundos."
        exit 1
    fi
done
echo "  mitmproxy PID: $MITM_PID"

# --- 2. Puente socat Unix socket → TCP mitmproxy ---
# El sandbox monta $PROXY_SOCK en su /tmp via --bind en bwrap.
# socat dentro del sandbox conecta a este socket con UNIX-CONNECT.
echo "Creando socket Unix: $PROXY_SOCK"
socat \
    UNIX-LISTEN:"$PROXY_SOCK",fork,reuseaddr \
    TCP:"$MITM_HOST":"$MITM_PORT" \
    &
SOCAT_PID=$!

# Verificar que el socket fue creado
for i in $(seq 1 6); do
    sleep 0.5
    [ -S "$PROXY_SOCK" ] && break
    if [ "$i" -eq 6 ]; then
        echo "ERROR: socat no creó el socket Unix en $PROXY_SOCK"
        exit 1
    fi
done
echo "  socat PID: $SOCAT_PID"
echo ""

echo "Proxy activo."
echo "  Tráfico HTTPS auditado por mitmproxy en $MITM_HOST:$MITM_PORT"
echo "  Socket sandbox: $PROXY_SOCK"
echo ""
echo "Primera vez: corre setup_first_run.sh para generar CA + poblar cert8.db:"
echo "  bash scripts/setup_first_run.sh"
echo ""

if $BG_MODE; then
    echo "$MITM_PID $SOCAT_PID" > "$PID_FILE"
    echo "Proxy corriendo en segundo plano (PID file: $PID_FILE)"
    # Desacoplar el trap para no matar los procesos al salir del script
    trap - EXIT
    exit 0
fi

echo "Ctrl+C para detener."
echo ""
wait "$MITM_PID"
