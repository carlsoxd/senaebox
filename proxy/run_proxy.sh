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

PROXY_SOCK="/tmp/senaebox-proxy.sock"
MITM_HOST="127.0.0.1"
MITM_PORT=8081
BG_MODE=false
PID_FILE="/tmp/senaebox-proxy.pid"

[[ "${1:-}" == "--bg" ]] && BG_MODE=true

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
mitmdump \
    --listen-host "$MITM_HOST" \
    --listen-port "$MITM_PORT" \
    &
MITM_PID=$!

# Esperar a que mitmproxy esté escuchando
for i in $(seq 1 10); do
    sleep 0.5
    if kill -0 "$MITM_PID" 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 10 ]; then
        echo "ERROR: mitmproxy no arrancó después de 5 segundos."
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
