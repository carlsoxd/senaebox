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
CONTAINER_IMAGE="${CONTAINER_IMAGE:-docker.io/appimagecrafters/appimage-builder:latest}"

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

# El SOURCE_REPO no debe tener datos personales sueltos. Hacemos un sanity
# scan rápido — solo alertas, no aborto (los excludes del YAML harán el trabajo
# real durante el build).
SUSPICIOUS=$(find "$SOURCE_REPO" -type f \
    \( -name "*.log" -o -name "*.csv" -o -name "*.mitm" -o -name "cookies.sqlite" \
       -o -name "*.bak" -o -name "*key*.pem" -o -name ".setup_complete" \
       -o -name ".ca_fingerprint" -o -name ".cert8*" -o -name ".zoom_configured*" \) \
    2>/dev/null | grep -v "\.git/" | head -10)

if [ -n "$SUSPICIOUS" ]; then
    echo "ADVERTENCIA: archivos potencialmente personales en SOURCE_REPO:"
    echo "$SUSPICIOUS"
    echo ""
    echo "Estos serán filtrados por los excludes del YAML, pero conviene limpiarlos."
    echo "Presiona Ctrl+C en 5s para cancelar, o espera para continuar..."
    sleep 5
fi

# El SOURCE_WINE_RUNNER NO debe tener un wineprefix interno
if [ -d "$SOURCE_WINE_RUNNER/drive_c" ]; then
    echo "ERROR: $SOURCE_WINE_RUNNER/drive_c existe."
    echo "       Eso es un wineprefix del builder — contiene datos personales."
    echo "       Borra ese drive_c/ o usa una copia limpia de wine-ge."
    exit 1
fi

# El SOURCE_SENAE_BROWSER puede tener Data/ — el rsync del YAML lo excluirá,
# pero advertimos por si el usuario quiere limpiarlo manualmente
if [ -d "$SOURCE_SENAE_BROWSER/Data" ]; then
    DATA_SIZE=$(du -sh "$SOURCE_SENAE_BROWSER/Data" 2>/dev/null | cut -f1)
    echo "AVISO: $SOURCE_SENAE_BROWSER/Data/ ($DATA_SIZE) presente."
    echo "       Será EXCLUIDO del AppImage automáticamente (contiene profile del builder)."
fi

# =============================================================================
# Preparar build directory
# =============================================================================

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Copiar los archivos del packaging/ al build dir (appimage-builder corre desde ahí)
cp "$PACKAGING_DIR/AppImageBuilder.yml" "$BUILD_DIR/"
cp "$PACKAGING_DIR/AppRun"               "$BUILD_DIR/"
cp "$PACKAGING_DIR/senaebox.desktop"     "$BUILD_DIR/"
cp "$PACKAGING_DIR/senaebox.svg"         "$BUILD_DIR/"
chmod +x "$BUILD_DIR/AppRun"

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
podman run --rm \
    --userns=keep-id \
    -v "$BUILD_DIR:/build:Z" \
    -v "$SOURCE_REPO:/sources/repo:ro,Z" \
    -v "$SOURCE_WINE_RUNNER:/sources/wine-runner:ro,Z" \
    -v "$SOURCE_SENAE_BROWSER:/sources/senae-browser:ro,Z" \
    -v "$OUTPUT_DIR:/output:Z" \
    -e SENAEBOX_VERSION="$SENAEBOX_VERSION" \
    -e SOURCE_REPO=/sources/repo \
    -e SOURCE_WINE_RUNNER=/sources/wine-runner \
    -e SOURCE_SENAE_BROWSER=/sources/senae-browser \
    -w /build \
    "$CONTAINER_IMAGE" \
    bash -c "
        set -euo pipefail
        apt-get update -q && apt-get install -y -q rsync python3-pip
        appimage-builder --recipe AppImageBuilder.yml --skip-tests
        mv SenaeBox-*.AppImage /output/
    "

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
