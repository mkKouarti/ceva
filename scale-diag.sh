#!/bin/bash
# scale-diag.sh
# Diagnostico y reparacion de fallos de bascula en estaciones EDAMS / AFT-X
#
# Uso:
#   sudo bash scale-diag.sh              # solo diagnostico (read-only)
#   sudo bash scale-diag.sh --fix-local  # intenta reparaciones locales seguras
#   sudo bash scale-diag.sh --verbose    # imprime mas detalle
#
# Reparaciones que aplica con --fix-local (todas reversibles, sin tocar deployment):
#   - Reinicia el servicio greengrass si esta inactivo
#   - Recarga el modulo usblp si el puerto serie esta presente pero el Lambda no responde
#   - Reinicia greengrass si MQTT no se ha conectado en los ultimos 10 minutos
#
# NO toca: certificados, config de Greengrass, deployments, ni nada cloud-side.

set -u

FIX=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --fix-local) FIX=1 ;;
    --verbose)   VERBOSE=1 ;;
    -h|--help)
      sed -n '2,17p' "$0"; exit 0 ;;
  esac
done

LOG=/tmp/scale-diag-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0; WARN=0; FIXED=0
NOTES=()

ok()    { echo "[ OK ] $*"; PASS=$((PASS+1)); }
bad()   { echo "[FAIL] $*"; FAIL=$((FAIL+1)); NOTES+=("FAIL: $*"); }
warn()  { echo "[WARN] $*"; WARN=$((WARN+1)); NOTES+=("WARN: $*"); }
info()  { echo "[INFO] $*"; }
fix()   { echo "[FIX ] $*"; FIXED=$((FIXED+1)); NOTES+=("FIX: $*"); }
hdr()   { echo; echo "===== $* ====="; }
vrb()   { [ "$VERBOSE" -eq 1 ] && echo "       $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta con sudo. Saliendo."
  exit 1
fi

hdr "Contexto"
echo "Host:     $(hostname)"
echo "Fecha:    $(date -Iseconds)"
echo "Uptime:   $(uptime -p)"
echo "Kernel:   $(uname -r)"
echo "Modo fix: $([ $FIX -eq 1 ] && echo si || echo no)"

# 1. Servicio greengrass
hdr "1. Servicio greengrass"
STATE=$(systemctl is-active greengrass 2>/dev/null || echo "unknown")
if [ "$STATE" = "active" ]; then
  ok "greengrass activo"
  vrb "$(systemctl show greengrass -p ActiveEnterTimestamp --value)"
else
  bad "greengrass NO activo (estado=$STATE)"
  if [ "$FIX" -eq 1 ]; then
    fix "Iniciando greengrass..."
    systemctl start greengrass && sleep 5
    STATE=$(systemctl is-active greengrass 2>/dev/null || echo "unknown")
    [ "$STATE" = "active" ] && fix "greengrass arrancado" || bad "No se pudo arrancar"
  fi
fi

# 2. Identidad del Thing
hdr "2. Identidad del Thing"
CFG=/greengrass/v2/config/config.yaml
if [ -f "$CFG" ]; then
  THING=$(grep -E '^\s*thingName:' "$CFG" | awk -F'"' '{print $2}')
  if [ -n "$THING" ]; then
    ok "Thing: $THING"
  else
    bad "thingName no encontrado en $CFG"
  fi
else
  bad "Config no existe: $CFG"
fi

# 3. Certificado IoT
hdr "3. Certificado IoT"
CERT=/greengrass/v2/certs/cert.pem
if [ -f "$CERT" ]; then
  NOT_AFTER=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$NOT_AFTER" ]; then
    EXP_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    DAYS=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
    if [ "$DAYS" -lt 0 ]; then
      bad "Certificado CADUCADO el $NOT_AFTER"
    elif [ "$DAYS" -lt 30 ]; then
      warn "Certificado caduca en $DAYS dias ($NOT_AFTER)"
    else
      ok "Certificado valido, caduca en $DAYS dias"
      vrb "$NOT_AFTER"
    fi
  else
    warn "No se pudo leer la fecha del certificado"
  fi
else
  bad "Certificado no existe: $CERT"
fi

# 4. Conexion MQTT a AWS IoT Core
hdr "4. Conexion MQTT a AWS IoT Core"
GG_LOG=/greengrass/v2/logs/greengrass.log
MQTT_OK_LINE=$(grep -i "Successfully connected to AWS IoT Core" "$GG_LOG" 2>/dev/null | tail -1)
MQTT_DISC_LINE=$(grep -iE "disconnect|connection lost" "$GG_LOG" 2>/dev/null | tail -1)
MQTT_AGE=999999
if [ -n "$MQTT_OK_LINE" ]; then
  MQTT_TS=$(echo "$MQTT_OK_LINE" | grep -oE '^[0-9-]+T[0-9:.]+Z' | head -1)
  if [ -n "$MQTT_TS" ]; then
    MQTT_EPOCH=$(date -d "$MQTT_TS" +%s 2>/dev/null || echo 0)
    MQTT_AGE=$(( $(date +%s) - MQTT_EPOCH ))
  fi
  ok "MQTT conecto a IoT Core (hace ${MQTT_AGE}s)"
  vrb "$MQTT_OK_LINE"
else
  bad "Sin 'Successfully connected to AWS IoT Core' en greengrass.log"
fi
if [ -n "$MQTT_DISC_LINE" ]; then
  warn "Evento reciente de disconnect/connection lost en log"
  vrb "$MQTT_DISC_LINE"
fi
if [ "$FIX" -eq 1 ] && [ "$MQTT_AGE" -gt 600 ] && [ "$STATE" = "active" ]; then
  fix "MQTT sin conectar reciente. Reiniciando greengrass..."
  systemctl restart greengrass && sleep 20
  NEW=$(grep -i "Successfully connected to AWS IoT Core" "$GG_LOG" 2>/dev/null | tail -1)
  [ -n "$NEW" ] && fix "MQTT reconectado" || warn "Reinicio hecho pero MQTT aun sin confirmar"
fi

# 5. Endpoint IoT alcanzable
hdr "5. Conectividad de red al endpoint IoT"
HOST=$(grep -E 'iotDataEndpoint' "$CFG" 2>/dev/null | awk -F'"' '{print $2}')
if [ -n "$HOST" ]; then
  if timeout 5 bash -c ">/dev/tcp/$HOST/8883" 2>/dev/null; then
    ok "TCP 8883 alcanza $HOST"
  else
    bad "No alcanza $HOST:8883 (firewall, DNS o proxy)"
  fi
else
  warn "iotDataEndpoint no encontrado en config; salto comprobacion"
fi

# 6. Deployment
hdr "6. Estado del ultimo deployment"
DEP=/greengrass/v2/deployments
if [ -d "$DEP" ]; then
  if [ -L "$DEP/previous-success" ]; then
    TARGET=$(readlink "$DEP/previous-success")
    ok "Ultimo deployment marcado previous-success"
    vrb "$TARGET"
  else
    warn "Sin symlink previous-success (deployment incompleto o nunca aplicado)"
  fi
  COUNT=$(find "$DEP" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
  vrb "$COUNT carpeta(s) de deployment en disco"
else
  bad "Directorio de deployments no existe: $DEP"
fi

# 7. Artefacto del Weight Lambda
hdr "7. Artefacto del Weight Lambda"
WJAR=$(find /greengrass/v2/packages/artifacts-unarchived/EdamsWeightDeviceLambda/ -name 'EdamsWeightDeviceLambda-*.jar' 2>/dev/null | head -1)
if [ -n "$WJAR" ]; then
  ok "Jar presente"
  vrb "$WJAR ($(stat -c %s "$WJAR") bytes)"
else
  bad "EdamsWeightDeviceLambda jar no encontrado"
fi

# 8. Lifecycle del Lambda
hdr "8. Lifecycle del Lambda"
LAST_STATE=$(grep -i "EdamsWeightDeviceLambda" "$GG_LOG" 2>/dev/null | grep -oE "currentState=[A-Z]+" | tail -1)
if [ -n "$LAST_STATE" ]; then
  info "Ultimo estado visto: $LAST_STATE"
  case "$LAST_STATE" in
    *RUNNING*) ok "Lambda ha estado RUNNING (ha procesado alguna invocacion)" ;;
    *NEW*)     ok "Lambda en NEW (normal: es on-demand, arranca cuando llega una invocacion)" ;;
    *BROKEN*)  bad "Lambda BROKEN. Redeploy desde la consola Greengrass" ;;
    *STOPPING*|*STOPPED*) warn "Lambda STOPPING/STOPPED" ;;
  esac
else
  warn "Sin registros de lifecycle del Lambda en greengrass.log"
fi

# 9. Puerto serie / FTDI
hdr "9. Puerto serie (FTDI)"
SERIAL=""
for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyACM0; do
  [ -e "$p" ] && { SERIAL="$p"; break; }
done
if [ -n "$SERIAL" ]; then
  ok "Puerto serie: $SERIAL"
  vrb "$(ls -l "$SERIAL")"
  vrb "$(stty -F "$SERIAL" -a 2>/dev/null | head -1)"
else
  warn "Sin /dev/ttyUSB* ni /dev/ttyACM* (puede ser bascula TCP-only)"
fi

# 10. Gateway local en puerto 87
hdr "10. Gateway local de bascula (TCP 87)"
GATEWAY_OK=0
if ss -tln 2>/dev/null | grep -qE ':87\b'; then
  ok "Algo escucha en el puerto 87"
  RESP=$(timeout 4 bash -c '
    exec 3<>/dev/tcp/127.0.0.1/87 || exit 1
    cat <&3 &
    READER=$!
    sleep 2
    kill $READER 2>/dev/null
  ' 2>/dev/null | tr -d '\r' | head -3)
  if echo "$RESP" | grep -qiE 'kg|lb|^S[[:space:]]'; then
    ok "Gateway devolvio peso:"
    echo "$RESP" | sed 's/^/       /'
    GATEWAY_OK=1
  elif [ -n "$RESP" ]; then
    warn "Gateway respondio sin patron de peso reconocible:"
    echo "$RESP" | sed 's/^/       /'
  else
    warn "Conexion aceptada pero sin datos en 2s (bascula apagada, cable o gateway colgado)"
    if [ "$FIX" -eq 1 ]; then
      fix "Reiniciando greengrass para revivir el gateway..."
      systemctl restart greengrass && sleep 20
    fi
  fi
else
  bad "Nada escucha en el puerto 87 (componente de bascula no expone su endpoint)"
  if [ "$FIX" -eq 1 ]; then
    fix "Reiniciando greengrass..."
    systemctl restart greengrass && sleep 20
  fi
fi

# 11. Frescura del log del Lambda
hdr "11. Log del Weight Lambda"
WLOG=/greengrass/v2/logs/EdamsWeightDeviceLambda.log
if [ -f "$WLOG" ]; then
  LAST_MOD=$(stat -c %Y "$WLOG")
  AGE=$(( $(date +%s) - LAST_MOD ))
  if [ "$AGE" -lt 600 ]; then
    ok "Log modificado hace ${AGE}s (actividad reciente)"
  else
    warn "Log sin actividad hace $((AGE/60)) min. Ninguna invocacion reciente."
  fi
  vrb "Ultimas lineas del log del Lambda:"
  tail -5 "$WLOG" 2>/dev/null | sed 's/^/       /'
else
  warn "$WLOG no existe (el Lambda nunca se ha invocado desde el ultimo despliegue)"
fi

# Resumen
hdr "RESUMEN"
echo "OK:    $PASS"
echo "WARN:  $WARN"
echo "FAIL:  $FAIL"
[ "$FIX" -eq 1 ] && echo "FIXED: $FIXED"
echo
echo "Hallazgos:"
if [ "${#NOTES[@]}" -eq 0 ]; then
  echo "  (ninguno)"
else
  for n in "${NOTES[@]}"; do echo "  - $n"; done
fi

# Guia
hdr "INTERPRETACION"
cat <<'EOF'
Lee de arriba a abajo. El primer FAIL que aparezca suele ser la causa raiz.

1. Todo OK pero la web sigue dando 502 al pesar:
   -> Local sano. El problema es cloud-side (routing IoT, policy o deployment
      group). Escalar a AWS / EDAMS con el thing name y este log adjunto.
      Comparar contra una estacion sana del mismo sitio.

2. Gateway en puerto 87 sin datos en 2s:
   -> Bascula apagada/desconectada o componente colgado. Revisar cable y power.
      Si todo fisico esta bien: sudo systemctl restart greengrass
      (con --fix-local se hace automatico).

3. Lambda en BROKEN:
   -> Captura log completo del Lambda y redeploy desde la consola Greengrass.

4. MQTT sin "Successfully connected" reciente:
   -> Red, certificado o reloj del sistema. Comprueba:
        date
        ping -c2 <iotDataEndpoint>
        sudo systemctl restart greengrass

5. Certificado caducado o por caducar:
   -> Provisionar nuevo cert desde AWS IoT y redeployar.

6. greengrass inactivo:
   -> sudo systemctl start greengrass
      Si falla: journalctl -u greengrass -n 100
EOF
echo
echo "Log completo guardado en: $LOG"
