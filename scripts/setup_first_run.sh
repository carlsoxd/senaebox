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
# 4. Verificar que el SENAE Browser está en su lugar + integridad
# =============================================================================

step 38 "Verificando archivos del SENAE Browser..."

SENAE_EXE="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/SENAE_browser_portable.exe"

# SHA-256 del SENAE_browser_portable.exe oficial entregado por SENAE Aduana
# del Ecuador (versión PortableApps 41.0.2.0, BuildID 20170629101550).
# Hash obtenido el 2026-05-18 del archivo en uso por el equipo de desarrollo.
# Tamaño esperado: 218,961 bytes.
#
# Si SENAE publica una nueva versión, actualizar este hash con el del binario
# oficial. Para sobrescribir manualmente (ej. desarrollo): exportar
# SENAEBOX_SKIP_BROWSER_HASH=1 antes de correr el setup.
SENAE_PORTABLE_SHA256="8886ceb86fe64315903ca89ef441e545d6af0779aef4b80f59540dffbf5dd79f"

if [ ! -f "$SENAE_EXE" ]; then
    fail "No se encontró SENAE_browser_portable.exe en:\n$SENAE_EXE\n\nCopia la carpeta 'SENAE browser' a esa ruta antes de continuar."
fi

if [ "${SENAEBOX_SKIP_BROWSER_HASH:-0}" = "1" ]; then
    echo "[setup] AVISO: SENAEBOX_SKIP_BROWSER_HASH=1 — verificación de hash omitida" >&2
else
    ACTUAL_HASH=$(sha256sum "$SENAE_EXE" | awk '{print $1}')
    if [ "$ACTUAL_HASH" != "$SENAE_PORTABLE_SHA256" ]; then
        fail "Hash SHA-256 de SENAE_browser_portable.exe no coincide.\n\n  Esperado: $SENAE_PORTABLE_SHA256\n  Obtenido: $ACTUAL_HASH\n\nEl binario puede estar corrupto, ser una versión diferente, o haber sido modificado. No se continúa por seguridad.\n\nPara forzar (solo si confías en la fuente): SENAEBOX_SKIP_BROWSER_HASH=1 bash launch.sh"
    fi
    echo "[setup] SENAE Browser: hash verificado OK" >&2
fi

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
# 6b. Copiar templates de configuración de Firefox al perfil
#
# El repo distribuye templates en assets/profile-templates/ con TODAS las
# prefs críticas (compositor, DPI neutralizado, TLS 1.2, anti-pantalla-negra,
# zoom Ecuapass habilitado, fullscreen deshabilitado, watchdog plugins, etc.)
# y el userChrome.css que oculta los controles fullscreen que crashean Wine.
#
# Solo se copian si el archivo destino NO existe — preserva customizaciones
# del usuario en re-instalaciones. Para forzar reemplazo, borrar el archivo
# local antes del setup.
# =============================================================================

step 65 "Instalando templates de configuración Firefox..."

PROFILE_DIR_FF="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/Data/profile"
TEMPLATE_DIR="$REPO_DIR/assets/profile-templates"

# El perfil debe existir antes — Firefox lo crea en su primer arranque, o el
# launcher del SENAE Browser PortableApps. Si no existe aún, crearlo vacío
# (Firefox lo poblará con prefs.js etc. al arrancar).
mkdir -p "$PROFILE_DIR_FF/chrome"

# Copia idempotente: solo si no existe en el perfil del usuario
_install_template() {
    local src="$1" dst="$2"
    if [ -f "$dst" ]; then
        echo "[setup]   $(basename "$dst") ya existe — preservado" >&2
        return 0
    fi
    if [ ! -f "$src" ]; then
        echo "[setup]   AVISO: template ausente en repo: $src" >&2
        return 1
    fi
    cp "$src" "$dst"
    echo "[setup]   Instalado: $(basename "$dst")" >&2
}

_install_template "$TEMPLATE_DIR/user.js"              "$PROFILE_DIR_FF/user.js"
_install_template "$TEMPLATE_DIR/chrome/userChrome.css" "$PROFILE_DIR_FF/chrome/userChrome.css"

# =============================================================================
# 7. Generar CA única para este usuario (NO viene del repo)
#
# A diferencia de la versión anterior que shipaba una CA estática en assets/
# (cualquiera con acceso al repo tenía la clave privada para firmar certs
# arbitrarios), aquí cada instalación genera SU PROPIA CA con openssl.
# La clave privada nunca sale del sistema del usuario, y solo es trusted por
# el Firefox de ESTE SenaeBox install.
#
# Permisos: directorio 700 (solo el usuario lo puede listar), key 600
# (otros usuarios del sistema no pueden leerla).
# =============================================================================

step 70 "Generando CA propia de este sistema..."

CA_DST_DIR="$STATE_DIR/ca"
CA_KEY="$CA_DST_DIR/senaebox-ca-key.pem"
CA_CERT="$CA_DST_DIR/mitmproxy-ca-cert.pem"
CA_COMBINED="$CA_DST_DIR/mitmproxy-ca.pem"   # mitmproxy busca este nombre

mkdir -p "$CA_DST_DIR"
chmod 700 "$CA_DST_DIR"

if [ -f "$CA_KEY" ] && [ -f "$CA_CERT" ] && [ -f "$CA_COMBINED" ]; then
    echo "[setup] CA ya existe en $CA_DST_DIR — no se regenera (borra el dir para forzar)" >&2
else
    # Config OpenSSL inline — CA constraints estándar para una root CA self-signed
    OSSL_CFG=$(mktemp /tmp/senaebox_ossl_XXXXXX.cnf)
    cat > "$OSSL_CFG" << 'EOF'
[req]
distinguished_name = req_dn
x509_extensions    = ca_ext
prompt             = no
[req_dn]
CN = SenaeBox CA (Local)
O  = SenaeBox
OU = TLS Inspection for Ecuapass
C  = EC
[ca_ext]
basicConstraints     = critical, CA:TRUE
keyUsage             = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
    openssl req -newkey rsa:2048 -nodes -x509 -days 3650 \
        -config "$OSSL_CFG" \
        -keyout "$CA_KEY" \
        -out    "$CA_CERT" 2>/dev/null \
        || fail "openssl falló al generar la CA."
    rm -f "$OSSL_CFG"

    # mitmproxy lee mitmproxy-ca.pem (key + cert concatenados)
    cat "$CA_KEY" "$CA_CERT" > "$CA_COMBINED"

    chmod 600 "$CA_KEY" "$CA_COMBINED"
    chmod 644 "$CA_CERT"
    echo "[setup] CA generada en $CA_DST_DIR/ (única para este sistema)" >&2
fi

# =============================================================================
# 7b. Generar cert8.db con la CA importada (vía podman temporal)
#
# Firefox 41 usa NSS 3.20 con cert8.db en formato DBM. Fedora 44+ eliminó el
# backend DBM en NSS, así que el certutil del host no puede escribir cert8.db.
# Workaround: AlmaLinux 8 (NSS 3.67, con DBM) corriendo en un contenedor podman.
#
# Si el usuario ya tiene podman instalado → usar y NO desinstalar al final.
# Si NO lo tiene → instalar via pkexec (1 prompt root), usar, desinstalar al
# final (1 prompt root más, combinable). Total: máximo 1 ciclo de prompts y
# solo en setup, nunca en arranques posteriores.
# =============================================================================

step 80 "Importando CA al cert8.db de Firefox..."

PROFILE_DIR_FF="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/Data/profile"
CERT8_TARGET="$PROFILE_DIR_FF/cert8.db"
CERT8_MARKER="$STATE_DIR/.cert8_ca_subject_sha"

# Hash del subject de NUESTRA CA (cambia si regeneramos) — sirve como marker
# para detectar si cert8.db necesita re-generación.
CA_SUBJECT_HASH=$(openssl x509 -in "$CA_CERT" -noout -subject_hash 2>/dev/null)
STORED_HASH=$(cat "$CERT8_MARKER" 2>/dev/null || echo "")

if [ -f "$CERT8_TARGET" ] && [ "$CA_SUBJECT_HASH" = "$STORED_HASH" ]; then
    echo "[setup] cert8.db ya tiene la CA correcta — skip podman" >&2
else
    echo "[setup] cert8.db necesita regenerarse con la CA nueva" >&2

    # Verificar/instalar podman
    PODMAN_PRE_EXISTING=true
    if ! command -v podman &>/dev/null; then
        PODMAN_PRE_EXISTING=false
        echo "[setup] Podman no instalado. Solicitando install vía pkexec..." >&2
        if command -v pkexec &>/dev/null; then
            # Aviso visible al usuario antes del prompt de pkexec — la barra de
            # zenity se queda estática durante el pkexec y dnf install (~30s).
            # Sin este aviso, el usuario puede no saber por qué aparece el dialog.
            if command -v zenity &>/dev/null; then
                zenity --info --title="SenaeBox — Setup" --width=460 --no-markup \
                    --text="A continuación se abrirá un diálogo del sistema pidiendo tu contraseña.\n\nSenaeBox necesita instalar 'podman' temporalmente para configurar el certificado de seguridad de Firefox. Se desinstalará automáticamente al terminar el setup." \
                    2>/dev/null &
                ZENITY_INFO_PID=$!
            fi
            pkexec dnf install -y podman \
                || fail "No se pudo instalar podman vía pkexec. Cancela el setup y ejecuta manualmente: sudo dnf install podman"
            [ -n "${ZENITY_INFO_PID:-}" ] && kill "$ZENITY_INFO_PID" 2>/dev/null || true
        else
            fail "Podman no instalado y pkexec no disponible.\nInstala manualmente: sudo dnf install podman\nLuego re-corre el setup."
        fi
        # Marker para registrar que NOSOTROS lo instalamos
        touch "$STATE_DIR/.podman_installed_by_senaebox"
        echo "[setup] Podman instalado (se desinstalará al final si no había nada antes)" >&2
    else
        echo "[setup] Podman ya estaba instalado — no se tocará al final" >&2
    fi

    # Backup si existía cert8.db previo
    if [ -f "$CERT8_TARGET" ]; then
        cp "$CERT8_TARGET" "$CERT8_TARGET.bak.$(date +%Y%m%d_%H%M%S)"
    fi

    # Generar cert8.db en staging y mover al profile
    CERT8_STAGING=$(mktemp -d /tmp/senaebox_cert8_XXXXXX)
    podman run --rm \
        -v "$CERT8_STAGING:/profile:Z" \
        -v "$CA_CERT:/ca.pem:ro,Z" \
        almalinux:8 \
        bash -c "
            dnf install -y nss-tools -q &>/dev/null
            certutil -d dbm:/profile -N --empty-password
            certutil -d dbm:/profile -A -n 'SenaeBox CA' -t 'CT,,' -i /ca.pem
        " >&2 || fail "podman/certutil falló al generar cert8.db"

    mv "$CERT8_STAGING/cert8.db" "$CERT8_TARGET"
    rm -rf "$CERT8_STAGING"
    echo "$CA_SUBJECT_HASH" > "$CERT8_MARKER"
    echo "[setup] cert8.db instalado con la CA local en $CERT8_TARGET" >&2

    # Si fuimos NOSOTROS quienes instalamos podman, desinstalarlo ahora
    if [ "$PODMAN_PRE_EXISTING" = false ] && [ -f "$STATE_DIR/.podman_installed_by_senaebox" ]; then
        echo "[setup] Desinstalando podman (lo instalamos solo para este setup)..." >&2
        # Aviso al usuario antes del segundo pkexec (mismo motivo que arriba).
        if command -v zenity &>/dev/null; then
            zenity --info --title="SenaeBox — Setup" --width=460 --no-markup \
                --text="Otra petición de contraseña: SenaeBox va a desinstalar el 'podman' que instaló temporalmente para configurar el certificado.\n\nDespués de este paso, SenaeBox no volverá a pedir contraseñas root." \
                2>/dev/null &
            ZENITY_INFO_PID=$!
        fi
        # --noautoremove: SOLO remueve podman, no toca paquetes que dnf considera
        # huérfanos. Si esos paquetes los necesita otra app del usuario, mantenerlos.
        # El usuario puede correr 'sudo dnf autoremove' manualmente si quiere limpiar.
        if pkexec dnf remove -y --noautoremove podman; then
            rm -f "$STATE_DIR/.podman_installed_by_senaebox"
            echo "[setup] Podman desinstalado. Arranques posteriores no lo necesitan." >&2
        else
            echo "[setup] ADVERTENCIA: no se pudo desinstalar podman automáticamente." >&2
            echo "[setup] Para removerlo manualmente: sudo dnf remove --noautoremove podman" >&2
        fi
        [ -n "${ZENITY_INFO_PID:-}" ] && kill "$ZENITY_INFO_PID" 2>/dev/null || true
    fi
fi

# =============================================================================
# 8. Crear carpetas compartidas
# =============================================================================

step 88 "Creando carpetas compartidas..."

mkdir -p "$HOME/SenaeBox/Descargas" "$HOME/SenaeBox/Documentos"
echo "[setup] ~/SenaeBox/Descargas y ~/SenaeBox/Documentos: OK" >&2

# Configurar directorio de descarga por defecto en Firefox (vía user.js)
#
# Usamos C:\users\<usuario>\Downloads (default FOLDERID_Downloads de Wine),
# que launch.sh convierte en symlink hacia ~/SenaeBox/Descargas mediante
# _ensure_downloads_symlink. Wine resuelve el symlink dentro del sandbox
# gracias al bind mount → las descargas aparecen en la carpeta compartida.
#
# Histórico: este bloque usaba "Z:\\home\\$WINE_USER\\SenaeBox\\Descargas"
# (drive Z = / por convención Wine), pero create_wineprefix.sh borra el
# symlink z: → / como parte del aislamiento → Z:\ apunta a nada → Firefox
# caía al default C:\users\.. que está dentro del wineprefix, no en
# ~/SenaeBox/Descargas. Por eso ahora usamos directamente el default y
# resolvemos vía symlink.
USERJS="$WINEPREFIX_DIR/drive_c/users/$WINE_USER/Documents/SENAE browser/Data/profile/user.js"
DOWNLOADS_WIN_PATH="C:\\\\users\\\\$WINE_USER\\\\Downloads"

if [ -f "$USERJS" ] && ! grep -q "browser.download.dir" "$USERJS"; then
    cat >> "$USERJS" << USERJS_EOF

// --- Directorio de descarga (añadido por setup_first_run.sh) ---
// Default de Wine FOLDERID_Downloads. launch.sh convierte
// drive_c/users/$WINE_USER/Downloads en symlink hacia ~/SenaeBox/Descargas,
// que está bind-montado en el sandbox.
user_pref("browser.download.folderList", 2);
user_pref("browser.download.dir", "$DOWNLOADS_WIN_PATH");
user_pref("browser.download.useDownloadDir", true);
USERJS_EOF
    echo "[setup] Directorio de descarga configurado: $DOWNLOADS_WIN_PATH" >&2
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
