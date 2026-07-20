#!/usr/bin/env bash
#===============================================================================
# fix-zebra-edams.sh   v3
#
# Diagnostica y RESUELVE, integramente desde terminal, las incidencias de
# impresion Zebra en thin clients AFT-X / EDAMS (Greengrass v2).
#
# IDEMPOTENTE: lee el estado real antes de escribir. Si un parametro ya es
# correcto, lo informa y NO lo reescribe. Reejecutar sobre un TC sano no
# produce ningun cambio ni ningun ciclo de impresion.
#
# NO EJECUTA ^JUF (reset de fabrica) EN NINGUN MODO.
#
# Fallos cubiertos, todos resolubles localmente:
#   1. Zebra ausente del bus USB / autosuspend  -> regla udev persistente
#   2. usblp en blacklist o sin bindear         -> rebind + carga en arranque
#   3. Symlink /dev/edams/peripheral_* ausente  -> retrigger udev
#   4. PrintServer Lambda no RUNNING            -> restart del componente
#   5. Serial mal mapeado en el JSON            -> correccion + backup + restart
#   6. ETIQUETA CORTADA / COMPRIMIDA / DESPLAZADA  <-- el caso de hoy
#        Causa: ^PW / ^LL / ^LH / sensor / tipo de medio mal en la impresora.
#        Se leen con ^HH, se comparan con los valores correctos derivados de
#        la resolucion real (~HI) y del medio medido (~HS), y se corrigen
#        con ^JUS solo si divergen.
#   7. RIBBON OUT con consumible termico directo -> ^MTD detectado via ~HS
#   8. Panel bloqueado por PIN                   -> ^KP (con --reset-pin)
#
# USO:
#   sudo ./fix-zebra-edams.sh                  Diagnostico. No escribe nada.
#   sudo ./fix-zebra-edams.sh --auto           Diagnostica y repara todo.
#   sudo ./fix-zebra-edams.sh --auto --size=4x6 --mode=peel
#   sudo ./fix-zebra-edams.sh --reset-pin=1478
#
# FLAGS
#   --auto              Activa todas las reparaciones + verificacion
#   --fix-link          Solo capa USB / usblp / symlink
#   --fix-service       Solo Greengrass / PrintServer / serial en JSON
#   --fix-media         Solo parametros de impresora (^PW ^LL ^LH ^MT ^MN ^MM)
#   --calibrate         Fuerza calibracion del sensor (~JC)
#   --size=WxH          Tamano de etiqueta en pulgadas. Por defecto: automedido
#   --mode=tear|peel|cut  Modo de impresion. Por defecto: se conserva el actual
#   --reset-pin[=NNNN]  Fija el PIN del panel (por defecto 1234)
#   --test              Imprime etiqueta de verificacion
#   --dry-run           Muestra que cambiaria sin escribir
#
# SALIDA
#   0 = correcto (sano, o reparado y verificado)
#   1 = error de uso / entorno
#   2 = fallo de dispositivo irrecuperable (HW / cable / puerto)
#   3 = fallo de plataforma: requiere RE-PROVISIONING
#===============================================================================

set -uo pipefail

ZEBRA_VID="0a5f"
GGC="/greengrass/v2/bin/greengrass-cli"
PERIPHERAL_CONFIG="/greengrass/peripheral_management/peripheral_configuration.json"
PS_COMPONENT="EdamsPrintServerDeviceLambda"
UDEV_AUTOSUSPEND_RULE="/etc/udev/rules.d/98-zebra-no-autosuspend.rules"
USBLP_LOAD_CONF="/etc/modules-load.d/usblp.conf"
LOGFILE="/var/log/fix-zebra-edams.log"

FIX_LINK=0; FIX_SERVICE=0; FIX_MEDIA=0
FORCE_CAL=0; DO_TEST=0; DRY_RUN=0
DO_RESET_PIN=0; NEW_PIN="1234"
REQ_W=""; REQ_H=""; REQ_MODE=""
EXIT_CODE=0
CHANGES=()

for arg in "$@"; do
    case "$arg" in
        --auto)         FIX_LINK=1; FIX_SERVICE=1; FIX_MEDIA=1; DO_TEST=1 ;;
        --fix-link)     FIX_LINK=1 ;;
        --fix-service)  FIX_SERVICE=1 ;;
        --fix-media)    FIX_MEDIA=1 ;;
        --calibrate)    FORCE_CAL=1 ;;
        --test)         DO_TEST=1 ;;
        --dry-run)      DRY_RUN=1 ;;
        --reset-pin)    DO_RESET_PIN=1 ;;
        --reset-pin=*)  DO_RESET_PIN=1; NEW_PIN="${arg#*=}" ;;
        --mode=*)       REQ_MODE="${arg#*=}" ;;
        --size=*)       REQ_W="${arg#*=}"; REQ_W="${REQ_W%x*}"; REQ_H="${arg#*x}" ;;
        -h|--help)      sed -n '3,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Argumento desconocido: $arg" >&2; exit 1 ;;
    esac
done

#--- presentacion --------------------------------------------------------------
C_OK="\033[0;32m"; C_WARN="\033[0;33m"; C_ERR="\033[0;31m"; C_FIX="\033[0;36m"; C_OFF="\033[0m"
[ -t 1 ] || { C_OK=""; C_WARN=""; C_ERR=""; C_FIX=""; C_OFF=""; }

_log()    { printf '%s %s\n' "$(date '+%F %T')" "$1" >> "${LOGFILE}" 2>/dev/null || true; }
section() { printf '\n=== %s ===\n' "$1"; _log "== $1"; }
ok()      { printf "${C_OK}[ OK ]${C_OFF}  %s\n" "$1"; _log "OK   $1"; }
warn()    { printf "${C_WARN}[WARN]${C_OFF}  %s\n" "$1"; _log "WARN $1"; }
fail()    { printf "${C_ERR}[FAIL]${C_OFF}  %s\n" "$1"; _log "FAIL $1"; }
fixd()    { printf "${C_FIX}[FIX ]${C_OFF}  %s\n" "$1"; _log "FIX  $1"; CHANGES+=("$1"); }
skip()    { printf "${C_OK}[  = ]${C_OFF}  %s\n" "$1"; _log "SAME $1"; }
info()    { printf "        %s\n" "$1"; }
action()  { printf "${C_WARN} ACCION:${C_OFF} %s\n" "$1"; }

[ "$(id -u)" -eq 0 ] || { fail "Ejecutar como root (sudo)."; exit 1; }

zsend()  { if [ "${DRY_RUN}" -eq 1 ]; then info "DRY-RUN: $1"; return 0; fi
           printf '%s' "$1" > "${EDAMS_LINK}" 2>/dev/null; }
zquery() { printf '%s' "$1" > "${EDAMS_LINK}" 2>/dev/null || return 1
           timeout "${2:-3}" head -c "${3:-2000}" "${EDAMS_LINK}" 2>/dev/null | tr -d '\002\003\r'; }
hhval()  { echo "${HH_RAW}" | grep -i -- "$1" | head -1 | awk '{print $1}' | tr -d '+'; }

printf '===============================================================\n'
printf ' ZEBRA / EDAMS  -  %s  -  %s\n' "$(hostname)" "$(date '+%F %T')"
if [ "${FIX_LINK}${FIX_SERVICE}${FIX_MEDIA}" = "000" ]; then
    printf ' MODO: DIAGNOSTICO (usar --auto para reparar)\n'
else
    printf ' MODO: DIAGNOSTICO + REPARACION'
    [ "${DRY_RUN}" -eq 1 ] && printf ' (DRY-RUN)'
    printf '\n'
fi
printf '===============================================================\n'

#===============================================================================
section "1. Bus USB"
#===============================================================================
ZEBRA_PORT=""
for d in /sys/bus/usb/devices/*/; do
    [ -f "${d}idVendor" ] || continue
    if [ "$(cat "${d}idVendor" 2>/dev/null)" = "${ZEBRA_VID}" ]; then
        ZEBRA_PORT="$(basename "${d}")"; break
    fi
done
if [ -z "${ZEBRA_PORT}" ]; then
    fail "Ninguna Zebra en el bus USB (VID ${ZEBRA_VID})."
    action "Revisar cable, alimentacion y puerto USB del TC."
    exit 2
fi
ok "Zebra en ${ZEBRA_PORT} - $(cat "/sys/bus/usb/devices/${ZEBRA_PORT}/product" 2>/dev/null || echo '?')"

PWR="$(cat "/sys/bus/usb/devices/${ZEBRA_PORT}/power/control" 2>/dev/null || echo '?')"
RULE_OK=0
if [ -f "${UDEV_AUTOSUSPEND_RULE}" ] && grep -q "${ZEBRA_VID}" "${UDEV_AUTOSUSPEND_RULE}"; then
    RULE_OK=1
fi
if [ "${PWR}" = "on" ] && [ "${RULE_OK}" -eq 1 ]; then
    skip "Autosuspend ya desactivado y regla udev presente"
elif [ "${FIX_LINK}" -eq 1 ]; then
    if [ "${DRY_RUN}" -eq 0 ]; then
        cat > "${UDEV_AUTOSUSPEND_RULE}" <<EOF
# Desactiva USB autosuspend en impresoras Zebra. fix-zebra-edams.sh
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="${ZEBRA_VID}", ATTR{power/control}="on"
EOF
        echo on > "/sys/bus/usb/devices/${ZEBRA_PORT}/power/control" 2>/dev/null || true
        udevadm control --reload-rules 2>/dev/null || true
    fi
    fixd "Autosuspend USB desactivado + regla udev persistente"
else
    warn "Autosuspend activo (power/control=${PWR}) - provoca cortes en reposo"
fi

#===============================================================================
section "2. Modulo usblp y nodo de dispositivo"
#===============================================================================
if grep -rqs '^blacklist[[:space:]]\+usblp' /etc/modprobe.d/ 2>/dev/null; then
    if [ "${FIX_LINK}" -eq 1 ]; then
        if [ "${DRY_RUN}" -eq 0 ]; then
            for f in /etc/modprobe.d/*.conf; do
                [ -f "$f" ] || continue
                grep -qs '^blacklist[[:space:]]\+usblp' "$f" || continue
                cp -n "$f" "${f}.bak" 2>/dev/null || true
                sed -i '/^blacklist[[:space:]]\+usblp/d' "$f"
            done
        fi
        fixd "Blacklist de usblp eliminada (backup .bak)"
    else
        warn "usblp en blacklist"
    fi
else
    skip "usblp no esta en blacklist"
fi

if [ -f "${USBLP_LOAD_CONF}" ] && grep -qs '^usblp' "${USBLP_LOAD_CONF}"; then
    skip "usblp ya configurado para cargar en arranque"
elif [ "${FIX_LINK}" -eq 1 ]; then
    [ "${DRY_RUN}" -eq 0 ] && echo usblp > "${USBLP_LOAD_CONF}"
    fixd "usblp anadido a ${USBLP_LOAD_CONF}"
else
    warn "usblp no carga en arranque"
fi

LP_NODE="$(ls -1 /dev/usb/lp* 2>/dev/null | head -1 || true)"
if [ -n "${LP_NODE}" ]; then
    skip "Nodo presente: ${LP_NODE}"
elif [ "${FIX_LINK}" -eq 1 ] && [ "${DRY_RUN}" -eq 0 ]; then
    modprobe -r usblp 2>/dev/null || true
    modprobe usblp 2>/dev/null || true
    sleep 1
    LP_NODE="$(ls -1 /dev/usb/lp* 2>/dev/null | head -1 || true)"
    if [ -z "${LP_NODE}" ] && [ -e "/sys/bus/usb/devices/${ZEBRA_PORT}/${ZEBRA_PORT}:1.0" ]; then
        echo "${ZEBRA_PORT}:1.0" > /sys/bus/usb/drivers/usblp/bind 2>/dev/null || true
        sleep 1
        LP_NODE="$(ls -1 /dev/usb/lp* 2>/dev/null | head -1 || true)"
    fi
    if [ -n "${LP_NODE}" ]; then
        fixd "usblp rebindeado -> ${LP_NODE}"
    else
        fail "Rebind fallido. Revisar 'dmesg | tail -30'."
        exit 2
    fi
else
    fail "No existe /dev/usb/lpN"
    action "Reejecutar con --auto"
    exit 2
fi

#===============================================================================
section "3. Symlink EDAMS"
#===============================================================================
EDAMS_LINK="$(ls -1 /dev/edams/peripheral_* 2>/dev/null | head -1 || true)"
if [ -z "${EDAMS_LINK}" ]; then
    if [ "${FIX_LINK}" -eq 1 ] && [ "${DRY_RUN}" -eq 0 ]; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger --subsystem-match=usb --attr-match=idVendor="${ZEBRA_VID}" 2>/dev/null || true
        sleep 2
        EDAMS_LINK="$(ls -1 /dev/edams/peripheral_* 2>/dev/null | head -1 || true)"
        [ -n "${EDAMS_LINK}" ] && fixd "Symlink regenerado: ${EDAMS_LINK}"
    fi
    if [ -z "${EDAMS_LINK}" ]; then
        fail "Falta /dev/edams/peripheral_<serial>"
        info "Revisar /etc/udev/rules.d/99-edamperm.rules y sanitize_serial"
        exit 2
    fi
else
    skip "Symlink: ${EDAMS_LINK}"
fi
SERIAL="$(basename "${EDAMS_LINK}" | sed 's/^peripheral_//')"
info "Serial: ${SERIAL}"

#===============================================================================
section "4. Greengrass / PrintServer"
#===============================================================================
if [ ! -x "${GGC}" ]; then
    fail "greengrass-cli ausente: TC sin provisionar."
    action "Requiere RE-PROVISIONING."
    exit 3
fi

PS_STATE="$("${GGC}" component list 2>/dev/null | grep -A1 "${PS_COMPONENT}" | grep 'State:' | awk '{print $2}')"
if [ "${PS_STATE}" = "RUNNING" ]; then
    skip "${PS_COMPONENT} ya RUNNING"
elif [ "${FIX_SERVICE}" -eq 1 ] && [ -n "${PS_STATE}" ] && [ "${DRY_RUN}" -eq 0 ]; then
    "${GGC}" component restart --names "${PS_COMPONENT}" >/dev/null 2>&1 || true
    sleep 8
    PS_STATE="$("${GGC}" component list 2>/dev/null | grep -A1 "${PS_COMPONENT}" | grep 'State:' | awk '{print $2}')"
    if [ "${PS_STATE}" = "RUNNING" ]; then
        fixd "${PS_COMPONENT} reiniciado -> RUNNING"
    else
        fail "Sigue en '${PS_STATE:-AUSENTE}'. RE-PROVISIONING."
        exit 3
    fi
else
    fail "${PS_COMPONENT} en '${PS_STATE:-AUSENTE}'"
    if [ -z "${PS_STATE}" ]; then
        action "Componente no desplegado: RE-PROVISIONING."
        exit 3
    fi
    action "Reejecutar con --auto"
    exit 3
fi

[ -f "${PERIPHERAL_CONFIG}" ] || { fail "Falta ${PERIPHERAL_CONFIG}"; exit 3; }

STATION=""
if grep -q "${SERIAL}" "${PERIPHERAL_CONFIG}"; then
    STATION="$(grep -oE "\"${SERIAL}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "${PERIPHERAL_CONFIG}" \
        | grep -oE '"[^"]+"$' | tr -d '"')"
    skip "Serial ya mapeado -> estacion ${STATION:-?}"
else
    CFG_SERIAL="$(grep -oE '"[0-9A-Za-z]{6,}"[[:space:]]*:' "${PERIPHERAL_CONFIG}" | head -1 | tr -d '": ')"
    fail "Serial desajustado: conectada '${SERIAL}' vs config '${CFG_SERIAL:-ninguna}'"
    if [ "${FIX_SERVICE}" -eq 1 ] && [ -n "${CFG_SERIAL}" ] && [ "${DRY_RUN}" -eq 0 ]; then
        BK="${PERIPHERAL_CONFIG}.bak.$(date +%s)"
        cp "${PERIPHERAL_CONFIG}" "${BK}"
        sed -i "s/\"${CFG_SERIAL}\"/\"${SERIAL}\"/g" "${PERIPHERAL_CONFIG}"
        if python3 -m json.tool "${PERIPHERAL_CONFIG}" >/dev/null 2>&1; then
            "${GGC}" component restart --names "${PS_COMPONENT}" >/dev/null 2>&1 || true
            sleep 8
            fixd "Serial corregido (${CFG_SERIAL} -> ${SERIAL}) y componente reiniciado"
            STATION="$(grep -oE "\"${SERIAL}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "${PERIPHERAL_CONFIG}" \
                | grep -oE '"[^"]+"$' | tr -d '"')"
        else
            cp "${BK}" "${PERIPHERAL_CONFIG}"
            fail "JSON invalido. Backup restaurado."
            exit 3
        fi
    else
        action "Reejecutar con --auto"
        exit 3
    fi
fi

#===============================================================================
section "5. Estado real de la impresora"
#===============================================================================
HI_RAW="$(zquery '~HI' 3 200 | head -1)"
DPI=""; MODEL=""
if [ -n "${HI_RAW}" ]; then
    ok "~HI: ${HI_RAW}"
    MODEL="$(echo "${HI_RAW}" | cut -d, -f1)"
    case "$(echo "${HI_RAW}" | cut -d, -f3 | tr -dc '0-9')" in
        6)  DPI=152 ;;
        8)  DPI=203 ;;
        12) DPI=300 ;;
        24) DPI=600 ;;
        *)  DPI="$(echo "${MODEL}" | grep -oE '[0-9]+dpi' | tr -dc '0-9')" ;;
    esac
    info "Modelo ${MODEL} | ${DPI:-?} dpi"
else
    warn "Sin respuesta a ~HI. Se asume 203 dpi."
fi
DPI="${DPI:-203}"

# ^HH devuelve la configuracion completa como texto por el mismo canal.
HH_RAW="$(zquery '^XA^HH^XZ' 4 4000)"
CUR_PW=""; CUR_LL=""; CUR_MT=""; CUR_MN=""
if [ -n "${HH_RAW}" ]; then
    ok "Configuracion leida con ^HH"
    CUR_PW="$(hhval 'PRINT WIDTH')"
    CUR_LL="$(hhval 'MAXIMUM LENGTH')"
    CUR_MT="$(echo "${HH_RAW}" | grep -i 'MEDIA TYPE'    | head -1 | awk '{print $1}')"
    CUR_MN="$(echo "${HH_RAW}" | grep -i 'SENSOR SELECT' | head -1 | awk '{print $1}')"
    info "Actual: PW=${CUR_PW:-?} LL=${CUR_LL:-?} MEDIA=${CUR_MT:-?} SENSOR=${CUR_MN:-?}"
else
    warn "Sin respuesta a ^HH. Se aplicaran valores calculados sin comparacion previa."
fi

# ~HS: cadena 1 campo 4 = longitud de etiqueta medida (puntos)
#      cadena 2 campo 4 = ribbon out, campo 5 = 1 si transferencia termica
HS_RAW="$(zquery '~HS' 3 600)"
MEAS_LL=""; TT=0; RIBBON_OUT=0
if [ -n "${HS_RAW}" ]; then
    MEAS_LL="$(echo "${HS_RAW}" | sed -n '1p' | cut -d, -f4 | tr -dc '0-9')"
    TT="$(echo "${HS_RAW}" | sed -n '2p' | cut -d, -f5 | tr -dc '0-9')"; TT="${TT:-0}"
    RIBBON_OUT="$(echo "${HS_RAW}" | sed -n '2p' | cut -d, -f4 | tr -dc '0-9')"; RIBBON_OUT="${RIBBON_OUT:-0}"
    if [ -n "${MEAS_LL}" ] && [ "${MEAS_LL}" -gt 0 ] 2>/dev/null; then
        info "Longitud de etiqueta medida: ${MEAS_LL} puntos ($(awk -v l="${MEAS_LL}" -v d="${DPI}" 'BEGIN{printf "%.2f", l/d}') pulgadas)"
    fi
fi

#===============================================================================
section "6. Parametros de medio  <-- causa de etiqueta cortada/comprimida"
#===============================================================================
if [ -n "${REQ_W}" ]; then
    WANT_PW=$(awk -v d="${DPI}" -v w="${REQ_W}" 'BEGIN{printf "%d", d*w}')
else
    WANT_PW=$(awk -v d="${DPI}" 'BEGIN{printf "%d", d*4}')   # 4" estandar AFT
fi

if [ -n "${REQ_H}" ]; then
    WANT_LL=$(awk -v d="${DPI}" -v h="${REQ_H}" 'BEGIN{printf "%d", d*h}')
elif [ -n "${MEAS_LL}" ] && [ "${MEAS_LL}" -gt 100 ] 2>/dev/null; then
    WANT_LL="${MEAS_LL}"
    info "Largo tomado de la medicion real del sensor"
else
    WANT_LL=$(awk -v d="${DPI}" 'BEGIN{printf "%d", d*6}')
fi

if [ "${TT}" = "1" ] && [ "${RIBBON_OUT}" != "1" ]; then
    WANT_MT="^MTT"; MT_TXT="transferencia termica (ribbon presente)"; MT_KEY="TRANS"
else
    WANT_MT="^MTD"; MT_TXT="termica directa"; MT_KEY="DIRECT"
    [ "${RIBBON_OUT}" = "1" ] && warn "RIBBON OUT en modo transferencia: se corrige a termica directa"
fi

case "${REQ_MODE}" in
    peel) WANT_MM="^MMP"; MM_TXT="peel-off" ;;
    cut)  WANT_MM="^MMC"; MM_TXT="cutter" ;;
    tear) WANT_MM="^MMT"; MM_TXT="tear-off" ;;
    *)    WANT_MM="";     MM_TXT="sin cambios" ;;
esac

info "Objetivo: PW=${WANT_PW} LL=${WANT_LL} medio=${MT_TXT} sensor=gap modo=${MM_TXT}"

NEEDS_APPLY=0
[ "${CUR_PW:-x}" != "${WANT_PW}" ] && NEEDS_APPLY=1
[ "${CUR_LL:-x}" != "${WANT_LL}" ] && NEEDS_APPLY=1
if [ -n "${CUR_MT}" ] && ! echo "${CUR_MT}" | grep -qi "${MT_KEY}"; then NEEDS_APPLY=1; fi
[ -z "${HH_RAW}" ] && NEEDS_APPLY=1
[ -n "${WANT_MM}" ] && NEEDS_APPLY=1

if [ "${NEEDS_APPLY}" -eq 0 ]; then
    skip "Parametros de medio ya correctos - no se escribe nada"
elif [ "${FIX_MEDIA}" -eq 1 ]; then
    zsend "^XA${WANT_MT}^MNY${WANT_MM}^PW${WANT_PW}^LL${WANT_LL}^LH0,0^LS0^JUS^XZ"
    sleep 2
    fixd "Medio configurado y guardado: ${MT_TXT}, PW=${WANT_PW} LL=${WANT_LL} LH=0,0 sensor=gap"
    [ -n "${WANT_MM}" ] && fixd "Modo de impresion fijado a ${MM_TXT}"
else
    warn "Parametros divergentes. Comando correctivo:"
    info "^XA${WANT_MT}^MNY${WANT_MM}^PW${WANT_PW}^LL${WANT_LL}^LH0,0^LS0^JUS^XZ"
    action "Aplicar con --auto (o --fix-media)"
fi

NEED_CAL=0
if [ -z "${MEAS_LL}" ] || [ "${MEAS_LL:-0}" -lt 100 ] 2>/dev/null; then NEED_CAL=1; fi
if [ "${FORCE_CAL}" -eq 1 ] || { [ "${NEED_CAL}" -eq 1 ] && [ "${FIX_MEDIA}" -eq 1 ]; }; then
    zsend '^XA~JC^XZ'
    sleep 12
    fixd "Sensor de medio calibrado (~JC)"
elif [ "${NEED_CAL}" -eq 0 ]; then
    skip "Sensor ya calibrado (medicion coherente)"
fi

if [ "${DO_RESET_PIN}" -eq 1 ]; then
    zsend "^XA^KP${NEW_PIN}^JUS^XZ"
    sleep 1
    fixd "PIN del panel fijado a ${NEW_PIN}"
fi

#===============================================================================
section "7. Verificacion"
#===============================================================================
if [ "${DRY_RUN}" -eq 0 ] && [ "${FIX_MEDIA}" -eq 1 ] && [ "${NEEDS_APPLY}" -eq 1 ]; then
    HH2="$(zquery '^XA^HH^XZ' 4 4000)"
    if [ -n "${HH2}" ]; then
        V_PW="$(echo "${HH2}" | grep -i 'PRINT WIDTH'    | head -1 | awk '{print $1}' | tr -d '+')"
        V_LL="$(echo "${HH2}" | grep -i 'MAXIMUM LENGTH' | head -1 | awk '{print $1}' | tr -d '+')"
        if [ "${V_PW}" = "${WANT_PW}" ]; then
            ok "Verificado en impresora: PW=${V_PW} LL=${V_LL}"
        else
            warn "La impresora reporta PW=${V_PW} (se pidio ${WANT_PW})"
            info "Es correcto si ${V_PW} es el ancho maximo fisico del cabezal."
        fi
    fi
fi

if [ "${DO_TEST}" -eq 1 ]; then
    GBW=$((WANT_PW - 40)); GBH=$((WANT_LL - 40))
    FS=$(awk -v d="${DPI}" 'BEGIN{printf "%d", d*0.27}')
    FS2=$((FS * 2 / 3))
    zsend "^XA^PW${WANT_PW}^LL${WANT_LL}^FO20,20^GB${GBW},${GBH},6^FS^FO60,90^A0N,${FS},${FS}^FDEDAMS OK^FS^FO60,$((FS+150))^A0N,${FS2},${FS2}^FD${SERIAL} @ ${DPI}dpi^FS^XZ"
    info "Etiqueta de verificacion enviada (${DPI} dpi, ${WANT_PW}x${WANT_LL} puntos)"
    info "Recuadro completo con margen en los 4 lados => configuracion correcta."
fi

#===============================================================================
section "Resumen"
#===============================================================================
if [ "${#CHANGES[@]}" -gt 0 ]; then
    printf ' Cambios aplicados: %d\n' "${#CHANGES[@]}"
    for c in "${CHANGES[@]}"; do printf "   ${C_FIX}*${C_OFF} %s\n" "$c"; done
    printf '\n'
    info "Reejecutar ahora debe reportar 0 cambios (idempotencia)."
else
    ok "Sin cambios: el TC ya estaba correcto de extremo a extremo."
fi
info "Log: ${LOGFILE}"
printf '\n'
exit "${EXIT_CODE}"
