#!/bin/bash
# Detecta el binario de Wine compatible con prefijos de 32 bits puros.
#
# NO ejecutar directamente. Usar con:
#   source "$(dirname "${BASH_SOURCE[0]}")/wine_env.sh"
#
# Exporta: WINE_BIN — ruta al binario wine compatible.
#
# Orden de búsqueda:
#   1. Variable $SENAEBOX_WINE (override manual del usuario)
#   2. wine-ge extraído en ~/.local/share/senaebox/wine-runner/
#   3. Runner de Bottles (Flatpak, auto-detectado)
#   4. Wine del sistema (solo si soporta WINEARCH=win32)
#
# Contexto: Wine 8+ en Fedora usa WoW64 por defecto y rechaza WINEARCH=win32.
# Los plugins NPAPI de 32 bits (Flash npjp2.dll, Java NPSWF32.dll) requieren
# un prefijo Win32 puro. wine-ge y los runners de Bottles los incluyen.

_senaebox_find_wine() {
    # 1. Override manual via variable de entorno
    if [[ -n "${SENAEBOX_WINE:-}" ]]; then
        if [[ -x "$SENAEBOX_WINE" ]]; then
            echo "  Fuente: variable SENAEBOX_WINE" >&2
            printf '%s' "$SENAEBOX_WINE"
            return 0
        else
            echo "  ERROR: SENAEBOX_WINE apunta a un archivo inexistente o no ejecutable:" >&2
            echo "    $SENAEBOX_WINE" >&2
            return 1
        fi
    fi

    # 2. wine-ge u otro runner extraído localmente
    local local_runner="$HOME/.local/share/senaebox/wine-runner/bin/wine"
    if [[ -x "$local_runner" ]]; then
        local ver
        ver=$("$local_runner" --version 2>/dev/null || echo "versión desconocida")
        echo "  Fuente: runner local ($ver)" >&2
        printf '%s' "$local_runner"
        return 0
    fi

    # 3. Runner de Bottles (Flatpak)
    local bottles_runners="$HOME/.var/app/com.usebottles.bottles/data/bottles/runners"
    if [[ -d "$bottles_runners" ]]; then
        local found
        # sort -r para preferir versiones más nuevas (nombre de carpeta)
        found=$(find "$bottles_runners" -name "wine" -type f 2>/dev/null | sort -r | head -1)
        if [[ -n "$found" && -x "$found" ]]; then
            local runner_name
            runner_name=$(basename "$(dirname "$(dirname "$found")")")
            echo "  Fuente: Bottles runner ($runner_name)" >&2
            printf '%s' "$found"
            return 0
        fi
    fi

    # 4. Wine del sistema — solo si soporta WINEARCH=win32
    if command -v wine &>/dev/null; then
        local test_dir="/tmp/senaebox_wine32_test_$$"
        if WINEDEBUG=-all WINEARCH=win32 WINEPREFIX="$test_dir" \
               wine wineboot --init &>/dev/null 2>&1; then
            rm -rf "$test_dir"
            local ver
            ver=$(wine --version 2>/dev/null || echo "versión desconocida")
            echo "  Fuente: wine del sistema ($ver)" >&2
            printf '%s' "wine"
            return 0
        fi
        rm -rf "$test_dir" 2>/dev/null || true
        echo "  wine del sistema detectado pero no soporta WINEARCH=win32 (WoW64-only)" >&2
    fi

    return 1
}

if ! WINE_BIN=$(_senaebox_find_wine); then
    cat >&2 <<'INSTRUCTIONS'

ERROR: No se encontró un Wine compatible con prefijos de 32 bits puros.

Wine 8+ en Fedora usa WoW64 y ya no soporta WINEARCH=win32.
Los plugins NPAPI de 32 bits (Flash, Java) requieren un prefijo Win32 puro.

────────────────────────────────────────────────────────────────
OPCIÓN A — wine-ge tarball (recomendada, más control):
────────────────────────────────────────────────────────────────
  1. Ve a: https://github.com/GloriousEggroll/wine-ge-custom/releases
     Descarga el archivo: wine-lutris-GE-ProtonXX-x86_64.tar.xz
     (elige la versión más reciente disponible)

  2. Extrae el tarball al directorio de SenaeBox:
       mkdir -p ~/.local/share/senaebox/wine-runner
       tar -xJf wine-lutris-GE-Proton*.tar.xz \
           -C ~/.local/share/senaebox/wine-runner/ \
           --strip-components=1

  3. Verifica que quedó en el lugar correcto:
       ls ~/.local/share/senaebox/wine-runner/bin/wine

  4. Vuelve a ejecutar este script.

────────────────────────────────────────────────────────────────
OPCIÓN B — Bottles (más fácil, vía GUI):
────────────────────────────────────────────────────────────────
  1. Instala Bottles:
       flatpak install flathub com.usebottles.bottles

  2. Abre Bottles → menú hamburguesa → Preferences → Runners
     Descarga el runner "wine-ge" (preferido) o "caffe"

  3. Vuelve a ejecutar este script (el runner se detecta automáticamente).

────────────────────────────────────────────────────────────────
OPCIÓN C — wine personalizado (avanzado):
────────────────────────────────────────────────────────────────
  Señala cualquier wine compatible mediante la variable de entorno:
    SENAEBOX_WINE=/ruta/a/tu/wine bash scripts/create_wineprefix.sh

INSTRUCTIONS
    exit 1
fi

export WINE_BIN
