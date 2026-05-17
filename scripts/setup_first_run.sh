#!/bin/bash
# SenaeBox — Configuración inicial (llamado por launch.sh)
#
# Salida a stdout: líneas para zenity --progress
#   "N"      → porcentaje (0-100)
#   "# Texto" → etiqueta visible en la barra de progreso
#
# Todo lo demás (logs de comandos) va a stderr → el launcher lo redirige al log.
#
# Termina con código 0 si todo fue bien, 1 si algo crítico falló.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$HOME/.local/share/senaebox"
WINEPREFIX_DIR="$STATE_DIR/wine"
WINE_USER=$(whoami)

# Archivos de instalador opcionales (el usuario los provee si los tiene)
JRE_INSTALLER="$REPO_DIR/installers/jre715.exe"

step() {
    local pct="$1"
    local msg="$2"
    echo "$pct"
    echo "# $msg"
    echo "[setup] $pct% — $msg" >&2
}

fail() {
    echo "1"
    echo "# Error: $*"
    echo "[setup] FALLO: $*" >&2
    exit 1
}

# =============================================================================
# 1. Verificar dependencias de setup
# =============================================================================

step 5 "Verificando herramientas necesarias..."

source "$SCRIPT_DIR/wine_env.sh" >&2 \
    || fail "No se encontró una versión de Wine compatible con prefijos de 32 bits. Instala wine-ge."

for cmd in winetricks podman openssl; do
    command -v "$cmd" &>/dev/null \
        || fail "Falta '$cmd'. Instálalo antes de continuar."
done
echo "[setup] Wine: $WINE_BIN" >&2

# Exponer el runner al PATH y a winetricks.
# winetricks busca 'wine' en $PATH y respeta la variable $WINE.
# Sin esto, winetricks usa el wine del sistema (WoW64-only en Fedora 44)
# y falla con "WINEARCH=win32 not supported in wow64 mode".
WINE_RUNNER_BIN="$(dirname "$WINE_BIN")"
export PATH="$WINE_RUNNER_BIN:$PATH"
export WINE="$WINE_BIN"
export WINESERVER="${WINE_BIN%wine}wineserver"
echo "[setup] winetricks usará: $WINE" >&2

# =============================================================================
# 2. Crear/verificar WINEPREFIX de 32 bits
# =============================================================================

step 15 "Configurando entorno Wine de 32 bits..."

if [ ! -d "$WINEPREFIX_DIR/drive_c" ]; then
    echo "[setup] Creando WINEPREFIX nuevo en $WINEPREFIX_DIR" >&2
    WINEARCH=win32 WINEPREFIX="$WINEPREFIX_DIR" "$WINE_BIN" wineboot --init >&2 \
        || fail "No se pudo inicializar el WINEPREFIX."
else
    echo "[setup] WINEPREFIX ya existe — verificando." >&2
fi

# =============================================================================
# 3. Instalar dependencias Windows via winetricks
# =============================================================================

step 28 "Instalando dependencias de Windows (vcrun2013)..."

WINEPREFIX="$WINEPREFIX_DIR" WINEARCH=win32 \
    winetricks --unattended vcrun2013 >&2 \
    || fail "No se pudo instalar vcrun2013 con winetricks."

echo "[setup] winetricks win7..." >&2
WINEPREFIX="$WINEPREFIX_DIR" WINEARCH=win32 \
    winetricks --unattended win7 >&2 \
    || echo "[setup] ADVERTENCIA: win7 falló — continuando." >&2

# =============================================================================
# 4. Verificar que el SENAE Browser está en su lugar
# =============================================================================

step 38 "Verificando archivos del SENAE Browser..."

SENAE_EXE="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/SENAE_browser_portable.exe"

if [ ! -f "$SENAE_EXE" ]; then
    fail "No se encontró SENAE_browser_portable.exe en:\n$SENAE_EXE\n\nCopia la carpeta 'SENAE browser' a esa ruta antes de continuar."
fi
echo "[setup] SENAE Browser: OK" >&2

# =============================================================================
# 5. Instalar JRE 7u15 (opcional — solo si el instalador está disponible)
# =============================================================================

step 48 "Verificando Java..."

JAVA_DLL="$WINEPREFIX_DIR/drive_c/Program Files/Java/jre7/bin/npjp2.dll"

if [ -f "$JAVA_DLL" ]; then
    echo "[setup] Java ya instalado — OK." >&2
elif [ -f "$JRE_INSTALLER" ]; then
    echo "[setup] Instalando JRE 7u15..." >&2

    # Verificar SHA-256 antes de ejecutar (requisito de seguridad del CLAUDE.md)
    JRE_EXPECTED_SHA="$(cat "$REPO_DIR/installers/jre715.exe.sha256" 2>/dev/null || echo "")"
    if [ -n "$JRE_EXPECTED_SHA" ]; then
        JRE_ACTUAL_SHA="$(sha256sum "$JRE_INSTALLER" | cut -d' ' -f1)"
        if [ "$JRE_ACTUAL_SHA" != "$JRE_EXPECTED_SHA" ]; then
            fail "El instalador de Java no pasó la verificación SHA-256.\nNo se instalará por seguridad."
        fi
    fi

    WINEPREFIX="$WINEPREFIX_DIR" WINEARCH=win32 \
        "$WINE_BIN" "$JRE_INSTALLER" /s >&2 \
        || fail "La instalación de Java falló."
    echo "[setup] Java instalado." >&2
else
    echo "[setup] ADVERTENCIA: instalador de JRE no encontrado en $JRE_INSTALLER" >&2
    echo "[setup] El applet de firma de Ecuapass requiere Java. Instálalo manualmente." >&2
    # No es fatal — el browser puede abrirse sin Java (PKI no funcionará)
fi

# =============================================================================
# 6. Configurar JARs PKI de Ecuapass
# =============================================================================

step 62 "Configurando certificados PKI de Ecuapass..."

if [ -f "$SCRIPT_DIR/setup_pki.sh" ]; then
    bash "$SCRIPT_DIR/setup_pki.sh" >&2 \
        || echo "[setup] ADVERTENCIA: setup_pki.sh tuvo errores — continuando." >&2
else
    echo "[setup] setup_pki.sh no encontrado — omitiendo PKI." >&2
fi

# =============================================================================
# 7. Generar certificado CA de mitmproxy
# =============================================================================

step 75 "Generando certificado de seguridad del proxy..."

MITM_CERT="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"

if [ ! -f "$MITM_CERT" ]; then
    echo "[setup] Iniciando mitmproxy brevemente para generar CA..." >&2
    # Arrancar mitmdump un momento solo para que genere la CA
    mitmdump --listen-host 127.0.0.1 --listen-port 18081 &
    MITM_INIT_PID=$!
    sleep 3
    kill "$MITM_INIT_PID" 2>/dev/null || true
    wait "$MITM_INIT_PID" 2>/dev/null || true

    if [ ! -f "$MITM_CERT" ]; then
        fail "mitmproxy no generó el certificado CA en $MITM_CERT"
    fi
    echo "[setup] Certificado CA generado." >&2
else
    echo "[setup] Certificado CA ya existe." >&2
fi

# =============================================================================
# 8. Crear carpetas compartidas
# =============================================================================

step 88 "Creando carpetas compartidas..."

mkdir -p "$HOME/SenaeBox/Descargas" "$HOME/SenaeBox/Documentos"
echo "[setup] ~/SenaeBox/Descargas y ~/SenaeBox/Documentos: OK" >&2

# Configurar directorio de descarga por defecto en Firefox (vía user.js)
USERJS="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/Data/profile/user.js"
DOWNLOADS_WIN_PATH="Z:\\\\home\\\\$WINE_USER\\\\SenaeBox\\\\Descargas"

if [ -f "$USERJS" ] && ! grep -q "browser.download.dir" "$USERJS"; then
    cat >> "$USERJS" << USERJS_EOF

// --- Directorio de descarga (Fase 6) ---
// La carpeta ~/SenaeBox/Descargas está montada en el sandbox con --bind.
// Firefox la ve como Z:\home\USER\SenaeBox\Descargas (drive Z = raíz del host).
user_pref("browser.download.folderList", 2);
user_pref("browser.download.dir", "$DOWNLOADS_WIN_PATH");
user_pref("browser.download.useDownloadDir", true);
USERJS_EOF
    echo "[setup] Directorio de descarga configurado en user.js." >&2
fi

# =============================================================================
# 9. Crear acceso directo en el escritorio
# =============================================================================

step 95 "Creando acceso directo en el escritorio..."

APPS_DIR="$HOME/.local/share/applications"
mkdir -p "$APPS_DIR"

cat > "$APPS_DIR/senaebox-browser.desktop" << DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=SENAE Browser
GenericName=Navegador Ecuapass
Comment=Accede al portal Ecuapass de la Aduana del Ecuador
Exec=$REPO_DIR/launch.sh
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
Keywords=ecuapass;aduana;senae;
DESKTOP_EOF

chmod +x "$APPS_DIR/senaebox-browser.desktop"

# Actualizar caché de aplicaciones para que aparezca en el menú
update-desktop-database "$APPS_DIR" 2>/dev/null || true

echo "[setup] Acceso directo creado en $APPS_DIR/senaebox-browser.desktop" >&2

# =============================================================================
# Fin
# =============================================================================

step 100 "Configuración completa"
echo "[setup] Setup finalizado correctamente." >&2
exit 0
