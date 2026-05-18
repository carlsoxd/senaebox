#!/bin/bash
# SenaeBox — Configurar zoom inicial para dominios de Ecuapass via userContent.css
#
# Por qué CSS y no Firefox per-site zoom:
#   Ecuapass usa <frameset> HTML4 con el contenido principal en un frame que
#   apunta a /ipt_server/ipt_flex/ipt_new.jsp. Firefox 41 aplica fullZoom al
#   <browser> XUL del tab (top-level), pero la propagación a frames hijos de
#   un frameset es inconsistente: el frame se carga en un docShell separado
#   que no siempre hereda el fullZoom del parent.
#
#   CSS zoom via @-moz-document se aplica a CADA documento independientemente,
#   incluyendo el contenido del frame. Es el workaround estándar para esta
#   limitación de framesets en Firefox <55.
#
# Sobre el doble zoom potencial:
#   Si el usuario presiona Ctrl++ en uno de estos dominios, Firefox guardará
#   fullZoom > 1.0 en content-prefs.sqlite. Ese fullZoom se MULTIPLICA con el
#   zoom CSS (no se suma). Para evitarlo, este script ASEGURA que las entradas
#   de content-prefs estén ausentes (default 1.0) para los dominios afectados,
#   limpiando cualquier valor previo que haya quedado.

set -euo pipefail

WINE_USER=$(whoami)
PROFILE="$HOME/.local/share/senaebox/wine/drive_c/users/$WINE_USER/Documents/SENAE browser/Data/profile"
USERCONTENT="$PROFILE/chrome/userContent.css"
DB="$PROFILE/content-prefs.sqlite"
STATE_DIR="$HOME/.local/share/senaebox"
MARKER_V1="$STATE_DIR/.zoom_configured_v1"   # versión vieja basada en DB
MARKER_V2="$STATE_DIR/.zoom_configured_v2"   # versión actual basada en CSS

DOMAINS=(
    "ecuapass.aduana.gob.ec"
    "ventanillaunica.aduana.gob.ec"
    "vuedes.aduana.gob.ec"
)
ZOOM="1.25"

# ---------------------------------------------------------------------------
# Contenido esperado de userContent.css
# ---------------------------------------------------------------------------

_expected_css() {
    cat << CSS_EOF
/*
 * SenaeBox — userContent.css
 *
 * Zoom $ZOOM aplicado a los dominios de Ecuapass que tienen layout de ancho
 * fijo. Workaround para framesets HTML4 que no propagan el fullZoom de
 * Firefox 41 a sus frames hijos consistentemente.
 *
 * LIMITACIÓN CONOCIDA: este zoom solo afecta al HTML que rodea al plugin
 * Flash (banners, navegación, formularios HTML). El contenido renderizado por
 * Flash (Stage del SWF) NO se ve afectado por CSS zoom — NPAPI windowed
 * plugins en Wine renderizan en su propia XWindow hija, completamente fuera
 * del pipeline de composición de Firefox. La única forma de escalar el
 * contenido Flash sería modificar Stage.scaleMode en los SWFs del servidor
 * de Ecuapass, lo cual está fuera del alcance de SenaeBox.
 *
 * Generado automáticamente por scripts/configure_zoom.sh — no editar a mano;
 * los cambios se sobrescribirán en el próximo arranque.
 */

@-moz-document
    domain(ecuapass.aduana.gob.ec),
    domain(ventanillaunica.aduana.gob.ec),
    domain(vuedes.aduana.gob.ec)
{
    html {
        zoom: $ZOOM !important;
    }
}
CSS_EOF
}

# ---------------------------------------------------------------------------
# 1. Escribir userContent.css si no existe o está desactualizado
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$USERCONTENT")"

EXPECTED=$(_expected_css)
if [ -f "$USERCONTENT" ] && [ "$(cat "$USERCONTENT")" = "$EXPECTED" ]; then
    CSS_UNCHANGED=true
else
    echo "$EXPECTED" > "$USERCONTENT"
    echo "[configure_zoom] userContent.css escrito → zoom $ZOOM para dominios Ecuapass"
    CSS_UNCHANGED=false
fi

# ---------------------------------------------------------------------------
# 2. Migración v1 → v2: limpiar fullZoom en content-prefs.sqlite para los
#    dominios gestionados.
#
#    Sin esto, el fullZoom del DB MULTIPLICA con el CSS zoom:
#      - DB ecuapass=2 × CSS 1.25 → final 2.5 (mucho)
#      - DB ventanillaunica=1.25 × CSS 1.25 → final 1.5625 (un poco más)
#
#    Borramos cualquier valor (no solo 1.25) porque el usuario pidió 1.25 como
#    baseline. Si después quiere ajustar, usa Ctrl++ sobre el sitio y Firefox
#    guarda un fullZoom que se multiplica con la CSS zoom — comportamiento
#    documentado y predecible.
#
#    Dominios fuera del array DOMAINS no se tocan (ej. www.aduana.gob.ec=1.5
#    se preserva — es preferencia del usuario sobre un sitio no gestionado).
# ---------------------------------------------------------------------------

if [ -f "$MARKER_V1" ] && [ -f "$DB" ]; then
    if ! command -v python3 &>/dev/null; then
        echo "[configure_zoom] python3 no disponible — saltando migración v1→v2 (no crítico)"
    else
        echo "[configure_zoom] Migrando de v1 a v2: reset de fullZoom en DB para dominios gestionados..."

        # Queries parametrizadas en Python (sqlite3.execute con ?) — previene SQL
        # injection si DOMAINS llega algún día a parametrizarse externamente.
        # Pasamos los dominios como argv para que el shell los entregue al Python
        # como argumentos POSIX (sin interpolación de string en la query).
        python3 - "$DB" "${DOMAINS[@]}" << 'PYEOF'
import sqlite3, sys
db_path = sys.argv[1]
domains = sys.argv[2:]
SETTING = "browser.content.full-zoom"

conn = sqlite3.connect(db_path)
cur  = conn.cursor()
try:
    for domain in domains:
        cur.execute("""
            SELECT p.value FROM prefs p
              JOIN groups   g ON p.groupID   = g.id
              JOIN settings s ON p.settingID = s.id
             WHERE g.name = ? AND s.name = ?
        """, (domain, SETTING))
        row = cur.fetchone()
        if row is None:
            continue
        old_value = row[0]

        cur.execute("""
            DELETE FROM prefs
             WHERE groupID   = (SELECT id FROM groups   WHERE name = ?)
               AND settingID = (SELECT id FROM settings WHERE name = ?)
        """, (domain, SETTING))
        print(f"  {domain}: fullZoom {old_value} en DB borrado")
    conn.commit()
finally:
    conn.close()
PYEOF
    fi
    rm -f "$MARKER_V1"
fi

# ---------------------------------------------------------------------------
# 3. Crear marker v2
# ---------------------------------------------------------------------------

mkdir -p "$STATE_DIR"
if [ ! -f "$MARKER_V2" ]; then
    touch "$MARKER_V2"
fi

# Salida silenciosa si nada cambió
if [ "$CSS_UNCHANGED" = "true" ] && [ -f "$MARKER_V2" ]; then
    exit 0
fi

echo "[configure_zoom] Configuración de zoom lista."
