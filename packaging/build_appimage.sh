#!/bin/bash
# SenaeBox — Build script para AppImage
#
# Usa podman + Ubuntu 22.04 + appimage-builder para crear un AppImage
# distribuible. Toma ~30-60 min y necesita ~10GB de disco temporal.
#
# Uso:
#   bash packaging/build_appimage.sh [version]
#
# Variables que puedes sobrescribir:
#   SENAEBOX_VERSION         (default: 1.0.0)
#   SOURCE_REPO              (default: <directorio padre del script>)
#   SOURCE_WINE_RUNNER       (default: ~/.local/share/senaebox/wine-runner)
#   SOURCE_SENAE_BROWSER     (default: ~/Documentos/SENAE browser)
#   BUILD_DIR                (default: ~/.cache/senaebox-appimage-build)
#   OUTPUT_DIR               (default: <directorio del script>/out)
#
# Pre-requisitos en el HOST builder:
#   - podman (para correr el container Ubuntu)
#   - ~10GB libres en $BUILD_DIR y $OUTPUT_DIR
#   - SENAE Browser portable copy a $SOURCE_SENAE_BROWSER (sin Data/, o con Data/
#     que será excluido automáticamente)
#   - wine-ge runner extraído a $SOURCE_WINE_RUNNER

set -euo pipefail

PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DEFAULT="$(cd "$PACKAGING_DIR/.." && pwd)"

# --- Variables configurables ---
SENAEBOX_VERSION="${SENAEBOX_VERSION:-${1:-1.0.0}}"
SOURCE_REPO="${SOURCE_REPO:-$REPO_DEFAULT}"
SOURCE_WINE_RUNNER="${SOURCE_WINE_RUNNER:-$HOME/.local/share/senaebox/wine-runner}"
SOURCE_SENAE_BROWSER="${SOURCE_SENAE_BROWSER:-$HOME/Documentos/SENAE browser}"
BUILD_DIR="${BUILD_DIR:-$HOME/.cache/senaebox-appimage-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$PACKAGING_DIR/out}"
# Ubuntu 22.04 (jammy) en lugar de la imagen oficial appimagecrafters/appimage-builder
# porque esa última usa Ubuntu bionic (18.04) con Python 3.6 — incompatible con
# mitmproxy 12 que requiere Python 3.10+. Jammy trae Python 3.10.6 nativo +
# glibc 2.35 (coincide con la base que documentamos para compatibilidad de
# binarios bundled). Coste: el container no tiene appimage-builder pre-instalado;
# lo instalamos desde pip en cada build (~2-3 min extra el primer arranque, luego
# está cacheado en la capa local de podman).
CONTAINER_IMAGE="${CONTAINER_IMAGE:-docker.io/library/ubuntu:22.04}"

echo "==============================================="
echo "  SenaeBox AppImage build"
echo "==============================================="
echo "  Versión:        $SENAEBOX_VERSION"
echo "  Repo source:    $SOURCE_REPO"
echo "  Wine runner:    $SOURCE_WINE_RUNNER"
echo "  SENAE Browser:  $SOURCE_SENAE_BROWSER"
echo "  Build dir:      $BUILD_DIR"
echo "  Output dir:     $OUTPUT_DIR"
echo "  Container:      $CONTAINER_IMAGE"
echo "==============================================="
echo ""

# =============================================================================
# Pre-flight checks
# =============================================================================

_check_or_die() {
    local what="$1" path="$2"
    if [ ! -e "$path" ]; then
        echo "ERROR: $what no encontrado en: $path"
        echo "       (Si está en otra ruta, exporta SOURCE_* env var)"
        exit 1
    fi
}

_check_or_die "Repo SenaeBox"           "$SOURCE_REPO/launch.sh"
_check_or_die "Wine-ge runner"          "$SOURCE_WINE_RUNNER/bin/wine"
_check_or_die "SENAE Browser portable"  "$SOURCE_SENAE_BROWSER/SENAE_browser_portable.exe"

if ! command -v podman &>/dev/null; then
    echo "ERROR: podman no instalado en el host."
    echo "       Fedora/RHEL: sudo dnf install podman"
    echo "       Ubuntu:      sudo apt install podman"
    exit 1
fi

# =============================================================================
# Privacy pre-flight: scan source for personal data
# =============================================================================

echo "=== Privacy pre-flight scan de las fuentes ==="

# El SOURCE_REPO no debe tener datos personales sueltos.
#
# IMPORTANTE: usamos `find -prune` para excluir .git/ EN LUGAR de `grep -v`.
# Razón: con bash + set -euo pipefail, un pipeline `find | grep -v | head` que
# no encuentra nada hace que grep -v retorne 1 (sin líneas para mostrar) →
# pipefail propaga ese 1 → la asignación VAR=$(pipeline) hereda exit 1 → set -e
# aborta el script silenciosamente. -prune evita el pipeline entero.
# Añadimos `|| true` como red de seguridad defensiva.
echo "  Buscando archivos potencialmente personales en $SOURCE_REPO..."
SUSPICIOUS=$(find "$SOURCE_REPO" \
    -type d \( -name ".git" -o -name ".claude" -o -name "node_modules" \) -prune -o \
    -type f \( -name "*.log" -o -name "*.csv" -o -name "*.mitm" \
            -o -name "cookies.sqlite" -o -name "*.bak" -o -name "*key*.pem" \
            -o -name ".setup_complete" -o -name ".ca_fingerprint" \
            -o -name ".cert8*" -o -name ".zoom_configured*" \) -print \
    2>/dev/null | head -10 || true)

if [ -n "$SUSPICIOUS" ]; then
    echo "  ADVERTENCIA: archivos potencialmente personales detectados:"
    echo "$SUSPICIOUS" | sed 's/^/    /'
    echo ""
    echo "  Estos serán filtrados por los excludes del YAML, pero conviene limpiarlos."
    echo "  Presiona Ctrl+C en 5s para cancelar, o espera para continuar..."
    sleep 5
else
    echo "  ✓ Sin archivos personales sueltos en el repo"
fi

# El SOURCE_WINE_RUNNER NO debe tener un wineprefix interno
echo "  Verificando wine-runner sin wineprefix interno..."
if [ -d "$SOURCE_WINE_RUNNER/drive_c" ]; then
    echo "  ERROR: $SOURCE_WINE_RUNNER/drive_c existe."
    echo "         Eso es un wineprefix del builder — contiene datos personales."
    echo "         Borra ese drive_c/ o usa una copia limpia de wine-ge."
    exit 1
fi
echo "  ✓ Wine-runner limpio (sin drive_c interno)"

# El SOURCE_SENAE_BROWSER puede tener Data/ — el rsync del YAML lo excluirá,
# pero advertimos por si el usuario quiere limpiarlo manualmente
echo "  Verificando SENAE Browser portable..."
if [ -d "$SOURCE_SENAE_BROWSER/Data" ]; then
    DATA_SIZE=$(du -sh "$SOURCE_SENAE_BROWSER/Data" 2>/dev/null | cut -f1 || echo "?")
    echo "  AVISO: $SOURCE_SENAE_BROWSER/Data/ ($DATA_SIZE) presente."
    echo "         Será EXCLUIDO del AppImage automáticamente (profile del builder)."
else
    echo "  ✓ SENAE Browser sin Data/ del builder"
fi

echo "=== Privacy pre-flight OK — continuando con preparación del build ==="

# =============================================================================
# Preparar build directory
# =============================================================================

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Copiar los archivos del packaging/ al build dir (appimage-builder corre desde ahí)
cp "$PACKAGING_DIR/AppImageBuilder.yml"             "$BUILD_DIR/"
cp "$PACKAGING_DIR/AppRun_wrapper.sh"                "$BUILD_DIR/"
cp "$PACKAGING_DIR/ec.gob.aduana.senaebox.desktop"   "$BUILD_DIR/"
cp "$PACKAGING_DIR/senaebox.svg"                     "$BUILD_DIR/"
chmod +x "$BUILD_DIR/AppRun_wrapper.sh"

# =============================================================================
# Ejecutar appimage-builder en container Ubuntu
# =============================================================================

echo ""
echo "=== Lanzando container Ubuntu 22.04 con appimage-builder ==="
echo "    (primera vez descarga ~1GB de imagen, build subsiguiente ~30 min)"
echo ""

# Bind mounts:
#   $BUILD_DIR (rw, contiene AppDir y AppImage final)
#   SOURCE_REPO (ro)
#   SOURCE_WINE_RUNNER (ro)
#   SOURCE_SENAE_BROWSER (ro)
#   OUTPUT_DIR (rw, destino final del .AppImage)
#
# Decisiones críticas del podman run:
#
# --user root (sin --userns=keep-id):
#   apt-get install necesita root DENTRO del container. Antes usábamos
#   --userns=keep-id para mapear el UID host (1000) en el container, pero eso
#   bloquea apt con "Permission denied". Sin keep-id, podman rootless usa el
#   mapping default subuid/subgid: UID 0 del container ↔ UID 1000 del host.
#   apt funciona como root dentro, y los archivos en /build aparecen en el host
#   con ownership correcto del usuario host.
#
# Variables UTF-8 (LANG, LC_ALL, PYTHONUTF8, PYTHONIOENCODING):
#   appimage-builder es Python; el container puede tener locale C (ASCII) por
#   default. PyYAML al leer AppImageBuilder.yml falla con UnicodeDecodeError si
#   el archivo tiene acentos/tildes/símbolos (todos nuestros comentarios en
#   español los tienen). Las 4 vars cubren todas las versiones de Python (2.7+ a
#   3.11+) y todos los paths de I/O (file reads, stdin/stdout, locale strings).
podman run --rm \
    --user root \
    -v "$BUILD_DIR:/build:Z" \
    -v "$SOURCE_REPO:/sources/repo:ro,Z" \
    -v "$SOURCE_WINE_RUNNER:/sources/wine-runner:ro,Z" \
    -v "$SOURCE_SENAE_BROWSER:/sources/senae-browser:ro,Z" \
    -v "$OUTPUT_DIR:/output:Z" \
    -e SENAEBOX_VERSION="$SENAEBOX_VERSION" \
    -e SOURCE_REPO=/sources/repo \
    -e SOURCE_WINE_RUNNER=/sources/wine-runner \
    -e SOURCE_SENAE_BROWSER=/sources/senae-browser \
    -e LANG=C.UTF-8 \
    -e LC_ALL=C.UTF-8 \
    -e PYTHONUTF8=1 \
    -e PYTHONIOENCODING=utf-8 \
    -w /build \
    "$CONTAINER_IMAGE" \
    bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        # ====================================================================
        # Bootstrap del container Ubuntu 22.04 con appimage-builder
        # ====================================================================
        #
        # System deps necesarias para:
        #   - appimage-builder: gnupg2, binutils, squashfs-tools, file, zsync,
        #                       desktop-file-utils, patchelf, fakeroot, strace
        #   - YAML script section: rsync (copia SENAE Browser sin Data/),
        #                          python3-venv (venv de mitmproxy)
        #   - downloads de appimagetool: wget, ca-certificates
        echo ">> apt update + instalación de deps del builder..."
        apt-get update -q
        # NOTA: los paquetes -bin / tools al final se instalan en el CONTAINER
        # (no en el AppDir). Los helpers de appimage-builder en
        # /usr/local/lib/python3.10/dist-packages/appimagebuilder/modules/setup/helpers/
        # los invocan durante "runtime setup" para regenerar caches. Sus
        # implementaciones usan shutil.which() / os.walk("/usr/lib"), o sea
        # buscan en el SISTEMA (el container), no en el AppDir.
        #
        # Mapeo helper → binario → paquete:
        #   GdkPixbuf  → gdk-pixbuf-query-loaders → libgdk-pixbuf2.0-bin
        #   GLib       → glib-compile-schemas    → libglib2.0-bin
        #   Gtk        → gtk-update-icon-cache   → gtk-update-icon-cache
        #   Mime       → update-mime-database    → shared-mime-info
        #   GStreamer  → gst-launch-1.0          → gstreamer1.0-tools
        apt-get install -y -q --no-install-recommends \
            python3 python3-pip python3-venv python3-setuptools \
            rsync gnupg2 binutils squashfs-tools file zsync wget \
            desktop-file-utils patchelf fakeroot strace \
            ca-certificates apt-utils \
            libgdk-pixbuf2.0-bin libglib2.0-bin gtk-update-icon-cache \
            shared-mime-info gstreamer1.0-tools

        # Habilitar la arquitectura i386 en dpkg para que appimage-builder
        # encuentre paquetes con sufijo :i386 (libc6:i386, libegl1:i386, etc.)
        # que Wine 32-bit necesita. Sin esto: "Unable to locate package libc6:i386"
        # porque dpkg rechaza el sufijo de arquitectura desconocida.
        echo ">> habilitando arch i386 en dpkg..."
        dpkg --add-architecture i386
        apt-get update -q

        # appimage-builder 1.x desde PyPI (soporta Python 3.10+ nativamente).
        #
        # IMPORTANTE: pineamos packaging<22 porque appimage-builder llama a
        # packaging.version.parse() para versiones de paquetes Ubuntu como
        # "1.21.1ubuntu2" o "1:2.4.1-3". En packaging<22 esos strings caían
        # automáticamente a LegacyVersion (acepta cualquier formato). En
        # packaging>=22 LegacyVersion fue ELIMINADA → InvalidVersion exception.
        # Pinearlo a <22 restaura el fallback hasta que appimage-builder migre
        # a apt_pkg.version_compare() o similar.
        # NOTA: usar double quotes "packaging<22" NO single quotes. Este script
        # entero corre dentro de un outer bash -c con single quotes, por lo que
        # cualquier apostrofe interno cierra el string del outer shell y rompe
        # el comando completo. Sintoma tipico: ENAMETOOLONG (Nombre de fichero
        # demasiado largo) porque bash recibe el script truncado y el resto
        # como argumentos de path.
        echo ">> pip install appimage-builder + packaging<22..."
        pip3 install --no-cache-dir "packaging<22" appimage-builder

        # appimagetool: binario AppImage que appimage-builder llama internamente.
        # Como AppImages necesitan FUSE para auto-montarse (no disponible en
        # containers sin --privileged), lo extraemos con --appimage-extract y
        # symlink el AppRun resultante.
        echo ">> instalando appimagetool..."
        wget -q -O /tmp/appimagetool.AppImage \
            "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
        chmod +x /tmp/appimagetool.AppImage
        cd /tmp && /tmp/appimagetool.AppImage --appimage-extract >/dev/null
        mv /tmp/squashfs-root /opt/appimagetool
        ln -sf /opt/appimagetool/AppRun /usr/local/bin/appimagetool
        rm -f /tmp/appimagetool.AppImage
        cd /build

        # ====================================================================
        # Build del AppImage
        # ====================================================================
        echo ">> ejecutando appimage-builder con AppImageBuilder.yml..."
        appimage-builder --recipe AppImageBuilder.yml --skip-tests

        # ====================================================================
        # Post-fix: restaurar shebang del wrapper python3-host.sh
        # ====================================================================
        # appimage-builder/apprun_2 ExecutablesPatcher corrompe TODOS los
        # shebangs (#!/bin/bash → #! bin/bash) y el flag preserve del YAML
        # no se aplica a archivos creados por el script section.
        # Extraemos el AppImage, restauramos el shebang con sed, y
        # re-empaquetamos con appimagetool.
        APPIMAGE=$(ls SenaeBox-*.AppImage | head -1)
        echo ">> post-fix: restaurando shebang de python3-host.sh..."
        ./"$APPIMAGE" --appimage-extract >/dev/null
        WRAPPER=squashfs-root/opt/senaebox/mitm-venv/bin/python3-host.sh
        if [ ! -f "$WRAPPER" ]; then
            echo "ERROR: wrapper no encontrado en $WRAPPER"; exit 1
        fi
        sed -i "1s|^#! bin/bash\$|#!/bin/bash|" "$WRAPPER"
        FIXED=$(head -1 "$WRAPPER")
        if [ "$FIXED" != "#!/bin/bash" ]; then
            echo "ERROR: shebang fix fallido. Línea 1 actual: $FIXED"; exit 1
        fi
        echo ">> shebang restaurado: $FIXED"

        # Re-empaquetar con appimagetool (mismo que usa appimage-builder)
        rm -f "$APPIMAGE"
        echo ">> re-empaquetando con appimagetool..."
        ARCH=x86_64 appimagetool squashfs-root "$APPIMAGE" 2>&1 | tail -5
        rm -rf squashfs-root

        if [ ! -f "$APPIMAGE" ]; then
            echo "ERROR: re-empaquetado fallido"; exit 1
        fi

        mv SenaeBox-*.AppImage /output/
    '

# =============================================================================
# Post-build verification
# =============================================================================

APPIMAGE_FILE="$OUTPUT_DIR/SenaeBox-${SENAEBOX_VERSION}-x86_64.AppImage"
if [ ! -f "$APPIMAGE_FILE" ]; then
    echo "ERROR: AppImage no se generó en $APPIMAGE_FILE"
    exit 1
fi

echo ""
echo "==============================================="
echo "  Build completado"
echo "==============================================="
echo "  AppImage:    $APPIMAGE_FILE"
echo "  Tamaño:      $(du -h "$APPIMAGE_FILE" | cut -f1)"
echo "  SHA-256:     $(sha256sum "$APPIMAGE_FILE" | cut -d' ' -f1)"
echo ""
echo "  Para probar:"
echo "    chmod +x '$APPIMAGE_FILE'"
echo "    '$APPIMAGE_FILE'"
echo ""
echo "  Publicar el SHA-256 junto al binario para verificación de integridad."
