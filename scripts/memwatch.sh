#!/bin/bash
# SenaeBox — Monitor de memoria Wine + Flash en tiempo real
#
# Uso: bash scripts/memwatch.sh [intervalo_s]
#      (por defecto: 5 segundos entre muestras)
#
# Corre en una terminal aparte ANTES de abrir el browser.
# Ctrl+C para terminar y ver el resumen.
#
# Qué monitorea (procesos del host visibles desde /proc):
#   - bwrap                   (sandbox — su muerte = browser cerrado)
#   - wine / wine-preloader   (procesos Wine principales)
#   - plugin-container        (Flash NPAPI — sospechoso de fuga de memoria)
#   - wineserver              (servidor Wine compartido)
#   - mitmdump                (proxy TLS — fuera del sandbox)
#
# Salida:
#   Terminal : tabla compacta en tiempo real
#   CSV log  : ~/.local/share/senaebox/logs/memwatch_FECHA.csv

INTERVAL="${1:-5}"
LOG_DIR="$HOME/.local/share/senaebox/logs"
mkdir -p "$LOG_DIR"
MEMLOG="$LOG_DIR/memwatch_$(date +%Y%m%d_%H%M%S).csv"

# --------------------------------------------------------------------------
# Identificar un proceso por su cmdline
# --------------------------------------------------------------------------
_label_pid() {
    local pid="$1"
    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return
    if   echo "$cmdline" | grep -qi "plugin.container";           then echo "plugin-container"
    elif echo "$cmdline" | grep -qi "SENAE_browser_portable";     then echo "firefox.exe"
    elif echo "$cmdline" | grep -qi "wineserver";                 then echo "wineserver"
    elif echo "$cmdline" | grep -qiE "wine-preloader|/wine[ $]"; then echo "wine"
    elif echo "$cmdline" | grep -qi "mitmdump";                   then echo "mitmdump"
    elif echo "$cmdline" | grep -qi "bwrap";                      then echo "bwrap"
    fi
}

# --------------------------------------------------------------------------
# Leer campos de /proc/PID/status (en KB)
# --------------------------------------------------------------------------
_rss_kb() {
    awk '/^VmRSS:/{print $2; exit}' "/proc/$1/status" 2>/dev/null || echo "0"
}
_vsz_kb() {
    awk '/^VmSize:/{print $2; exit}' "/proc/$1/status" 2>/dev/null || echo "0"
}
# RssAnon = heap anónimo residente (crece con fugas de ActionScript/C heap)
# RssFile = páginas de archivo mapeadas (SWF/DLL en RAM, no necesariamente fuga)
_rss_anon_kb() {
    awk '/^RssAnon:/{print $2; exit}' "/proc/$1/status" 2>/dev/null || echo "0"
}
_rss_file_kb() {
    awk '/^RssFile:/{print $2; exit}' "/proc/$1/status" 2>/dev/null || echo "0"
}

# --------------------------------------------------------------------------
# Encontrar todos los PIDs relevantes — imprime "PID LABEL" por línea
# --------------------------------------------------------------------------
_find_pids() {
    for pid_dir in /proc/[0-9]*/; do
        local pid="${pid_dir%/}"
        pid="${pid#/proc/}"
        [ -d "$pid_dir" ] || continue
        local label
        label=$(_label_pid "$pid" 2>/dev/null) || continue
        [ -n "$label" ] && printf '%s %s\n' "$pid" "$label"
    done
}

# --------------------------------------------------------------------------
# Tracking de picos: archivos temporales para evitar subshell
# --------------------------------------------------------------------------
PEAK_DIR=$(mktemp -d /tmp/senaebox_memwatch_XXXXXX)
FIRST_DIR="$PEAK_DIR/first"
mkdir -p "$FIRST_DIR"

_record() {
    local label="$1" rss="$2"
    local peak_file="$PEAK_DIR/$label"
    local first_file="$FIRST_DIR/$label"

    if [ ! -f "$first_file" ]; then
        echo "$rss" > "$first_file"
    fi
    echo "$rss" > "$PEAK_DIR/${label}.last"

    local prev_peak=0
    [ -f "$peak_file" ] && prev_peak=$(cat "$peak_file")
    if [ "$rss" -gt "$prev_peak" ]; then
        echo "$rss" > "$peak_file"
    fi
}

START_TS=$(date +%s)
SAMPLE_COUNT=0

# --------------------------------------------------------------------------
# Imprimir resumen final
# --------------------------------------------------------------------------
_print_summary() {
    local elapsed=$(( $(date +%s) - START_TS ))
    echo ""
    echo "══════════════════════════════════════════════════════"
    printf "  RESUMEN — %s\n" "$(date)"
    printf "  Duración: %ds  |  Muestras: %d\n" "$elapsed" "$SAMPLE_COUNT"
    echo "══════════════════════════════════════════════════════"
    printf "  %-22s %7s %7s %7s %9s\n" "PROCESO" "INICIO" "PICO" "FIN" "CRECIM"
    printf "  %-22s %7s %7s %7s %9s\n" "──────────────────────" "───────" "───────" "───────" "─────────"

    for peak_file in "$PEAK_DIR"/*.last; do
        [ -f "$peak_file" ] || continue
        local label
        label=$(basename "$peak_file" .last)
        local first peak last growth
        first=$(cat "$FIRST_DIR/$label" 2>/dev/null || echo "0")
        peak=$(cat "$PEAK_DIR/$label" 2>/dev/null || echo "0")
        last=$(cat "$peak_file")
        growth=$(( last - first ))

        local f_mb p_mb l_mb g_mb
        f_mb=$(( first / 1024 ))
        p_mb=$(( peak / 1024 ))
        l_mb=$(( last / 1024 ))
        g_mb=$(( growth / 1024 ))

        local color="\033[0m"
        local warn=""
        if [ "$g_mb" -gt 50 ]; then
            color="\033[1;31m"; warn=" ⚠  FUGA PROBABLE"
        elif [ "$g_mb" -gt 20 ]; then
            color="\033[1;33m"; warn=" ↑  crecimiento alto"
        fi

        printf "  %-22s %5d MB %5d MB %5d MB " "$label" "$f_mb" "$p_mb" "$l_mb"
        printf "${color}%+d MB%b%s\n" "$g_mb" "\033[0m" "$warn"
    done

    echo "══════════════════════════════════════════════════════"
    echo "  Log CSV: $MEMLOG"
    echo ""
}

_cleanup() {
    _print_summary
    rm -rf "$PEAK_DIR"
    exit 0
}
trap '_cleanup' INT TERM EXIT

# --------------------------------------------------------------------------
# Encabezado del CSV
# --------------------------------------------------------------------------
echo "epoch,timestamp,pid,label,rss_kb,vsz_kb" > "$MEMLOG"

echo ""
echo "  SenaeBox — Monitor de memoria  (intervalo: ${INTERVAL}s)"
echo "  Log: $MEMLOG"
echo "  Ctrl+C para terminar y ver resumen."
echo ""

# Esperar a que bwrap arranque (máx 60 s)
echo "  Esperando que el browser arranque (bwrap)..."
waited=0
while ! pgrep -x bwrap &>/dev/null; do
    sleep 1
    waited=$(( waited + 1 ))
    if [ "$waited" -ge 60 ]; then
        echo "  Aviso: bwrap no detectado en 60s. Muestreando igual..."
        break
    fi
done
pgrep -x bwrap &>/dev/null && echo "  bwrap detectado. Comenzando muestreo."
echo ""

# --------------------------------------------------------------------------
# Encabezado de tabla
# --------------------------------------------------------------------------
_print_header() {
    printf "\033[1;37m%-12s %-22s %6s %8s %8s\033[0m\n" \
        "HORA" "PROCESO" "PID" "RSS MB" "VSZ MB"
    printf '%s\n' "──────────────────────────────────────────────────────"
}

# --------------------------------------------------------------------------
# Bucle principal de muestreo
# --------------------------------------------------------------------------
BWRAP_WAS_ALIVE=false
pgrep -x bwrap &>/dev/null && BWRAP_WAS_ALIVE=true

while true; do
    NOW=$(date +%s)
    TS=$(date '+%H:%M:%S')
    SAMPLE_COUNT=$(( SAMPLE_COUNT + 1 ))

    # Reimprimir encabezado cada 20 muestras
    if [ $(( (SAMPLE_COUNT - 1) % 20 )) -eq 0 ]; then
        _print_header
    fi

    TOTAL_RSS=0
    BWRAP_SEEN=false

    while IFS=" " read -r pid label; do
        rss=$(_rss_kb "$pid")
        vsz=$(_vsz_kb "$pid")
        rss_mb=$(( rss / 1024 ))
        vsz_mb=$(( vsz / 1024 ))

        _record "$label" "$rss"
        [ "$label" = "bwrap" ] && BWRAP_SEEN=true

        if [ "$label" = "plugin-container" ]; then
            rss_anon=$(_rss_anon_kb "$pid")
            rss_file=$(_rss_file_kb "$pid")
            rss_anon_mb=$(( rss_anon / 1024 ))
            rss_file_mb=$(( rss_file / 1024 ))
            printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$NOW" "$TS" "$pid" "$label" "$rss" "$vsz" "$rss_anon" "$rss_file" >> "$MEMLOG"

            # >350 MB → rojo; >200 MB → amarillo
            if [ "$rss_mb" -gt 350 ]; then
                printf "\033[1;31m%-12s %-22s %6d %8d  [heap %d MB + file %d MB]\033[0m\n" \
                    "$TS" "$label" "$pid" "$rss_mb" "$rss_anon_mb" "$rss_file_mb"
            elif [ "$rss_mb" -gt 200 ]; then
                printf "\033[1;33m%-12s %-22s %6d %8d  [heap %d MB + file %d MB]\033[0m\n" \
                    "$TS" "$label" "$pid" "$rss_mb" "$rss_anon_mb" "$rss_file_mb"
            else
                printf "%-12s %-22s %6d %8d  [heap %d MB + file %d MB]\n" \
                    "$TS" "$label" "$pid" "$rss_mb" "$rss_anon_mb" "$rss_file_mb"
            fi
        else
            printf '%s,%s,%s,%s,%s,%s\n' "$NOW" "$TS" "$pid" "$label" "$rss" "$vsz" >> "$MEMLOG"
            printf "%-12s %-22s %6d %8d\n" "$TS" "$label" "$pid" "$rss_mb"
        fi

        TOTAL_RSS=$(( TOTAL_RSS + rss ))
    done < <(_find_pids | sort -k2)

    TOTAL_MB=$(( TOTAL_RSS / 1024 ))
    printf "\033[1;37m%-12s %-22s %6s %8d\033[0m\n" \
        "" "── TOTAL RSS ──" "" "$TOTAL_MB"
    echo ""

    # Detectar muerte de bwrap = browser cerrado
    if $BWRAP_WAS_ALIVE && ! $BWRAP_SEEN; then
        echo "  ⚡ bwrap terminó — el browser se cerró en $TS."
        break
    fi
    $BWRAP_SEEN && BWRAP_WAS_ALIVE=true

    sleep "$INTERVAL"
done
# El trap EXIT llama a _cleanup → _print_summary
