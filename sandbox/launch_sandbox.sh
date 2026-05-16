#!/bin/bash
# Lanza el SENAE Browser dentro de un sandbox Bubblewrap (Fase 3).
#
# FASE 3 — Sandbox activo, sin proxy TLS.
# El proceso Wine queda aislado del sistema de archivos y los namespaces del host
# (PID, UTS). La red permanece activa hasta Fase 4.
# IPC namespace se comparte deliberadamente con el host (ver sección --unshare-*).
#
# ADVERTENCIA: NO uses para trámites reales — sin proxy TLS el tráfico no está auditado.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WINEPREFIX_DIR="$HOME/.local/share/senaebox/wine"
LOG_DIR="$HOME/.local/share/senaebox/logs"
WINE_USER=$(whoami)

# Usamos el launcher PortableApps como punto de entrada. El launcher crea Firefox
# y sale inmediatamente; el script interno luego llama a "wineserver --wait" para
# mantener el sandbox vivo hasta que Firefox (y cualquier otro proceso Wine) termine.
SENAE_EXE_WIN="C:\\users\\$WINE_USER\\Documents\\SENAE browser\\SENAE_browser_portable.exe"
SENAE_EXE_LINUX="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/SENAE_browser_portable.exe"

echo "=== SenaeBox — Fase 3 (Bubblewrap, sin proxy TLS) ==="
echo ""

# --- Detectar Wine compatible ---

echo "Buscando Wine compatible..."
source "$REPO_DIR/scripts/wine_env.sh"
echo "  Wine: $WINE_BIN"
echo ""

# --- Verificaciones previas ---

if ! command -v bwrap &>/dev/null; then
    echo "ERROR: bubblewrap no está instalado."
    echo "  Instala con: sudo dnf install bubblewrap"
    exit 1
fi

if [ ! -d "$WINEPREFIX_DIR" ]; then
    echo "ERROR: WINEPREFIX no configurado."
    echo "  Ejecuta: bash scripts/create_wineprefix.sh"
    exit 1
fi

if [ ! -f "$SENAE_EXE_LINUX" ]; then
    echo "ERROR: SENAE_browser_portable.exe no encontrado."
    echo "  Ruta esperada: $SENAE_EXE_LINUX"
    echo "  Copia la carpeta 'SENAE browser' desde Windows a esa ubicación."
    exit 1
fi

# --- Detectar socket X11 ---

if [ -z "${DISPLAY:-}" ]; then
    echo "ERROR: Variable DISPLAY no definida. Ejecuta en una sesión gráfica."
    exit 1
fi

# ":0" → "0",  ":0.0" → "0"
DISPLAY_NUM="${DISPLAY#:}"
DISPLAY_NUM="${DISPLAY_NUM%%.*}"
X11_SOCKET="/tmp/.X11-unix/X${DISPLAY_NUM}"

if [ ! -S "$X11_SOCKET" ]; then
    echo "ERROR: Socket X11 no encontrado: $X11_SOCKET"
    echo "  Verifica que DISPLAY=$DISPLAY apunta a una sesión activa."
    exit 1
fi

# --- Detectar archivo Xauthority ---
# X11 usa un "magic cookie" (MIT-MAGIC-COOKIE-1) para autenticar clientes.
# Sin él, el X server rechaza toda conexión con "Authorization required".
# En Fedora/GNOME con Mutter+XWayland, el archivo lo genera Mutter en cada sesión
# en /run/user/UID/.mutter-Xwaylandauth.XXXXXX, no en ~/.Xauthority.
# La variable $XAUTHORITY de la sesión siempre apunta al archivo correcto.

XAUTH_FILE="${XAUTHORITY:-$HOME/.Xauthority}"

if [ ! -f "$XAUTH_FILE" ]; then
    echo "ERROR: Archivo Xauthority no encontrado en: $XAUTH_FILE"
    echo "  Define la variable XAUTHORITY o verifica tu sesión gráfica."
    exit 1
fi

# --- Detectar socket PulseAudio (compatible con PipeWire-pulse en Fedora) ---

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
PULSE_SOCKET="$XDG_RUNTIME_DIR/pulse/native"
PULSE_AVAILABLE=false

if [ -S "$PULSE_SOCKET" ]; then
    PULSE_AVAILABLE=true
else
    echo "ADVERTENCIA: Socket PulseAudio no encontrado en $PULSE_SOCKET"
    echo "  El audio no funcionará dentro del sandbox. Continuando..."
    echo ""
fi

# --- Preparar log ---

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/bwrap_$(date +%Y%m%d_%H%M%S).log"

{
    echo "SenaeBox — Log de Bubblewrap (Fase 3)"
    echo "Fecha   : $(date)"
    echo "Usuario : $WINE_USER"
    echo "DISPLAY : $DISPLAY (socket: $X11_SOCKET)"
    echo "Xauth   : $XAUTH_FILE"
    echo "Pulse   : $PULSE_SOCKET (activo: $PULSE_AVAILABLE)"
    echo "Wine    : $WINE_BIN"
    echo "Exe     : $SENAE_EXE_LINUX"
    echo "---"
} > "$LOG_FILE"

# --- Limpiar lock stale del perfil ---
# bwrap mata Wine sin cierre limpio, por lo que parent.lock nunca se borra.
# Firefox detecta el archivo y asume otra instancia activa → salida limpia (código 0).
PROFILE_DIR="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/Data/profile"
rm -f "$PROFILE_DIR/parent.lock"

# --- Preparar mms.cfg para Flash ---
# NPSWF32_25_0_0_171.dll tiene su propio pipeline de GPU (Stage3D/Direct3D9)
# completamente separado del compositor de Firefox. Las prefs de layers.* en
# user.js controlan Firefox, pero no llegan a Flash. La única forma de forzar
# renderizado por CPU en Flash es mms.cfg — Adobe lo lee siempre desde
# C:\Windows\System32\Macromed\Flash\ sin importar dónde está la DLL.
MMS_DIR="$WINEPREFIX_DIR/drive_c/windows/system32/Macromed/Flash"
MMS_CFG="$MMS_DIR/mms.cfg"
if [ ! -f "$MMS_CFG" ]; then
    mkdir -p "$MMS_DIR"
    printf 'DisableHardwareAcceleration=1\n' > "$MMS_CFG"
    echo "  mms.cfg: creado — GPU de Flash desactivada"
fi

# --- Construir argumentos de bwrap ---

BWRAP_ARGS=(
    # Sistema base (read-only)
    --ro-bind /usr /usr

    # Fedora usa merged-/usr: /bin, /lib, /lib64, /sbin son symlinks a /usr/*.
    # --symlink los recrea correctamente en el sandbox sin duplicar el bind de /usr.
    --symlink usr/bin   /bin
    --symlink usr/lib   /lib
    --symlink usr/lib64 /lib64
    --symlink usr/sbin  /sbin

    # Configuración mínima del sistema
    --ro-bind     /etc/alternatives        /etc/alternatives
    --ro-bind-try /etc/fonts               /etc/fonts
    --ro-bind-try /etc/localtime           /etc/localtime
    # machine-id: Wine lo usa para generar UUIDs estables (claves de caché,
    # COM, crypto). Sin él, Wine genera un UUID aleatorio en cada arranque;
    # Firefox invalida su caché de perfil y puede fallar en la inicialización.
    --ro-bind-try /etc/machine-id          /etc/machine-id

    # DNS y certificados TLS: necesarios mientras --share-net esté activo.
    # Se eliminan en Fase 4 cuando el proxy TLS gestione todo el tráfico.
    --ro-bind-try /etc/resolv.conf         /etc/resolv.conf
    --ro-bind-try /etc/nsswitch.conf       /etc/nsswitch.conf
    --ro-bind-try /etc/pki/tls             /etc/pki/tls
    --ro-bind-try /etc/ssl                 /etc/ssl

    # Filesystems virtuales aislados
    --proc /proc
    --tmpfs /dev
    --dev-bind /dev/null    /dev/null
    --dev-bind /dev/urandom /dev/urandom
    --dev-bind /dev/zero    /dev/zero
    --tmpfs /dev/shm

    # /tmp aislado — se pre-crea el directorio del socket X11 antes del bind
    --dir /tmp
    --dir /tmp/.X11-unix
    --ro-bind "$X11_SOCKET"  "$X11_SOCKET"
    # Xauthority: el cookie de autenticación que el X server exige a cada cliente.
    # Sin este bind, wine y xrdb reciben "Authorization required" y no arrancan.
    # Mutter genera el archivo en /run/user/UID/ con nombre aleatorio por sesión;
    # la variable $XAUTHORITY siempre apunta al correcto para la sesión actual.
    --ro-bind  "$XAUTH_FILE" "$XAUTH_FILE"
    --setenv   XAUTHORITY    "$XAUTH_FILE"

    # $HOME vacío: Wine intenta hacer chdir() al home del usuario al arrancar.
    # Sin este directorio, Wine imprime "could not open working directory" y
    # arranca desde C:\Windows, lo que puede afectar rutas relativas en Wine.
    # Es un tmpfs vacío — los writes son temporales y se descartan al cerrar.
    # IMPORTANTE: bwrap --dir NO crea directorios padre. /home debe crearse
    # explícitamente antes de /home/luis; de lo contrario --dir "$HOME" falla
    # silenciosamente porque /home no existe en el sandbox.
    --dir /home
    --dir "$HOME"

    # /run aislado
    --dir /run
    --dir "$XDG_RUNTIME_DIR"

    # WINEPREFIX con escritura — Wine escribe el estado del browser aquí
    --bind "$WINEPREFIX_DIR" "$WINEPREFIX_DIR"

    # Aislamiento de namespaces — se listan explícitamente en lugar de usar
    # --unshare-all para poder OMITIR el namespace IPC deliberadamente.
    #
    # Por qué NO se aisla el namespace IPC:
    # Wine's x11drv usa la extensión X11 MIT-SHM (XShmPutImage) para renderizado
    # rápido. MIT-SHM crea segmentos de memoria compartida con shmget() (System V
    # IPC) que el X server adjunta via XShmAttach(). Con --unshare-ipc, el X server
    # (en el namespace IPC del host) no puede ver los segmentos creados dentro del
    # sandbox (namespace IPC nuevo). Eso provoca que XShmAttach falle con BadAccess;
    # el error handler de Wine en Firefox 41 no lo recupera y plugin-container crashea
    # con mozglue+0x25be int $3. La solución correcta es compartir el namespace IPC.
    #
    # Namespaces que sí se aíslan:
    --unshare-pid          # Wine no puede ver ni matar procesos del host
    --unshare-uts          # hostname aislado (Wine no puede cambiar hostname)
    --unshare-cgroup-try   # cgroup aislado si el kernel lo permite
    # Red compartida — TEMPORAL hasta Fase 4 (proxy TLS + --unshare-net)
    --die-with-parent
    --new-session

    # Variables de entorno dentro del sandbox
    --setenv DISPLAY               "$DISPLAY"
    --setenv WINEPREFIX            "$WINEPREFIX_DIR"
    --setenv WINEARCH              "win32"
    # LIBGL_ALWAYS_SOFTWARE=1: deshabilita la detección de GPU en Mesa y va
    # directamente al path de software sin intentar abrir /dev/dri.
    # Afecta al proceso principal de Firefox Y a plugin-container.exe (hijo),
    # porque los procesos hijos heredan el entorno del sandbox.
    # Firefox 41 y plugin-container crashean con STATUS_BREAKPOINT cuando
    # Wine intenta usar dxgi_resource_GetSharedHandle (no implementado en Wine).
    --setenv LIBGL_ALWAYS_SOFTWARE   "1"
    # GALLIUM_DRIVER=llvmpipe: selecciona explícitamente el driver Gallium de
    # software. LIBGL_ALWAYS_SOFTWARE activa el path de software pero en algunas
    # builds de Mesa el driver elegido puede ser softpipe (más lento) en lugar de
    # llvmpipe (JIT, más rápido y más compatible con D3D9 de Wine).
    --setenv GALLIUM_DRIVER          "llvmpipe"
    --setenv HOME                  "$HOME"
    --setenv USER                  "$WINE_USER"
    --setenv LOGNAME               "$WINE_USER"
    # Usadas por el script interno del sandbox (ver sección siguiente)
    --setenv WINE_BIN              "$WINE_BIN"
    --setenv SENAE_EXE_WIN         "$SENAE_EXE_WIN"
)

# Wine runner — si no es el wine del sistema, su directorio raíz debe ser accesible
case "$WINE_BIN" in
    /usr/*)
        # Sistema: ya cubierto por --ro-bind /usr /usr
        ;;
    *)
        # Runner local (wine-ge, Bottles): bind del directorio padre de bin/wine
        WINE_RUNNER_DIR="$(cd "$(dirname "$WINE_BIN")/.." && pwd)"
        BWRAP_ARGS+=(--ro-bind "$WINE_RUNNER_DIR" "$WINE_RUNNER_DIR")
        ;;
esac

# PulseAudio / PipeWire-pulse — solo si el socket existe
if $PULSE_AVAILABLE; then
    BWRAP_ARGS+=(
        --bind   "$PULSE_SOCKET" "$PULSE_SOCKET"
        --setenv PULSE_SERVER    "unix:$PULSE_SOCKET"
    )
fi

# --- Script interno del sandbox ---
# Se crea un script temporal en lugar de pasar la lógica como argumento a
# bash -c, para evitar la complejidad de escapar rutas con espacios y backslashes.
#
# $WINE_BIN y $SENAE_EXE_WIN se expanden dentro del sandbox desde las variables
# de entorno inyectadas por --setenv (el heredoc usa 'INNER_EOF' para no expandirlas
# en el script exterior).
#
# xrdb ajusta el DPI reportado por XWayland a todas las ventanas de la sesión X.
# Valor 120 = 125% de 96 DPI, calibrado para el HP EliteBook 840 G8 (1920×1080, 14").
# Nota: xrdb actúa sobre el X server global porque el socket se comparte;
# el ajuste es visible fuera del sandbox mientras el browser esté abierto.

INNER_SCRIPT=$(mktemp /tmp/senaebox_inner_XXXXXX.sh)
trap 'rm -f "$INNER_SCRIPT"' EXIT

cat > "$INNER_SCRIPT" << 'INNER_EOF'
#!/bin/bash
set -e
# WINE_BIN es p. ej. /ruta/bin/wine; el wineserver está junto a wine.
WINESERVER_BIN="${WINE_BIN%wine}wineserver"

xrdb -override <<< 'Xft.dpi: 120'

# Lanza el launcher PortableApps. Hace el setup del perfil y crea Firefox, luego sale.
# No usamos exec porque necesitamos seguir corriendo después de que el launcher salga.
"$WINE_BIN" "$SENAE_EXE_WIN"

# El launcher salió pero Firefox sigue vivo, conectado al wineserver.
# wineserver --wait bloquea hasta que TODOS los procesos Wine (Firefox, plugin-container,
# etc.) hayan terminado. Esto mantiene el sandbox vivo el tiempo que el usuario use el browser.
exec "$WINESERVER_BIN" --wait
INNER_EOF
chmod +x "$INNER_SCRIPT"

BWRAP_ARGS+=(--ro-bind "$INNER_SCRIPT" /run/senaebox_launch.sh)

# --- Mostrar resumen y lanzar ---

echo "  Ejecutable : $SENAE_EXE_LINUX"
echo "  Log bwrap  : $LOG_FILE"
echo "  Wine       : $WINE_BIN"
echo "  Sandbox    : activo (Bubblewrap)"
echo ""
echo "  ADVERTENCIA: Fase 3 — sin proxy TLS. Red directa (--share-net temporal)."
echo "  No uses para trámites reales hasta Fase 4."
echo ""
echo "Iniciando SENAE Browser en sandbox..."
echo ""

# set +e/set -e: captura el exit code de bwrap sin que set -euo pipefail
# termine el script antes del bloque de reporte de abajo.
set +e
bwrap "${BWRAP_ARGS[@]}" \
    /bin/bash /run/senaebox_launch.sh \
    2>>"$LOG_FILE"
EXIT_CODE=$?
set -e

echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
    echo "Browser cerrado normalmente (código: 0)."
else
    echo "Browser cerrado con código de error: $EXIT_CODE"
    echo ""
    echo "Revisa el log:"
    echo "  $LOG_FILE"
    echo ""
    echo "Pistas comunes en el log:"
    echo "  'Permission denied'  — falta un bind en el sandbox (agregar a BWRAP_ARGS)"
    echo "  'err:module'         — DLL no accesible dentro del sandbox"
    echo "  'err:ole'            — problema COM/DCOM"
    echo "  'fixme:heap'         — puede ignorarse"
fi
