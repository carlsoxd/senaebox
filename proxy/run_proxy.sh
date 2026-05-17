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
# Primera vez (instalar CA de mitmproxy en Firefox):
#   bash scripts/install_proxy_cert.sh

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

mitmdump \
    --listen-host "$MITM_HOST" \
    --listen-port "$MITM_PORT" \
    --set stream_large_bodies=100k \
    "${ADDON_ARGS[@]}" \
    "${FLOW_ARGS[@]}" \
    &
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
echo "Primera vez: instala el certificado CA en Firefox:"
echo "  bash scripts/install_proxy_cert.sh"
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
