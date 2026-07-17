#!/usr/bin/env bash
#
# setup-wifi-tc104.sh
# 1) Instala el driver correcto del RTL8188EUS  ->  modulo 8188eu (DKMS, repo aircrack-ng)
#    con RED DE SEGURIDAD: si algo falla, NO te deja sin red (revierte a rtl8xxxu).
# 2) Aplica el endurecimiento (power-save off, autoconnect, bloqueo de usuarios).
#
# REQUISITOS:
#   - Internet UNA vez (comparte datos desde un movil por USB: Ajustes > Conexion compartida por USB).
#   - Secure Boot DESACTIVADO (un modulo DKMS sin firmar no carga). El script lo comprueba y aborta si esta ON.
#
# Uso:  sudo ./setup-wifi-tc104.sh
#
set -uo pipefail
log(){ echo -e "\n==> $*"; }
die(){ echo -e "\n!! $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ejecutalo con sudo."

DRV=8188eu ; VER=5.3.9 ; SRC="/usr/src/${DRV}-${VER}"
KVER="$(uname -r)"
IFACE="$(ls /sys/class/net 2>/dev/null | grep -E '^wlx' | head -n1 || true)"
log "Kernel: $KVER   Interfaz USB wifi: ${IFACE:-<no detectada>}"

# --- 0) Secure Boot -----------------------------------------------------------
if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    die "Secure Boot ACTIVADO: un driver DKMS sin firmar no cargara. Desactivalo en la BIOS/UEFI y relanza. NO he tocado nada."
  fi
fi

# --- 1) Dependencias (necesita internet) --------------------------------------
log "Instalando dependencias (dkms, headers, compilador)... (necesita internet)"
export DEBIAN_FRONTEND=noninteractive
apt-get update || die "apt update fallo. ¿Tienes internet (movil por USB)? El driver actual sigue INTACTO."
apt-get install -y dkms build-essential git "linux-headers-$KVER" \
  || apt-get install -y dkms build-essential git linux-headers-generic \
  || die "No pude instalar headers/dkms. Driver actual INTACTO."
[ -d "/lib/modules/$KVER/build" ] || die "Faltan los headers de $KVER. Driver actual INTACTO."

# --- 2) Descargar y COMPILAR el driver (sin tocar el que funciona) ------------
log "Descargando y compilando el driver $DRV $VER..."
if dkms status 2>/dev/null | grep -q "${DRV}/${VER}"; then
  dkms remove "${DRV}/${VER}" --all 2>/dev/null || true
fi
rm -rf "$SRC"
git clone --depth 1 https://github.com/aircrack-ng/rtl8188eus "$SRC" \
  || die "Clone del repo fallo. Driver actual INTACTO."

dkms add   -m "$DRV" -v "$VER" || die "dkms add fallo. Driver actual INTACTO."
if ! dkms build -m "$DRV" -v "$VER"; then
  echo "----- ultimas lineas del log de compilacion -----"
  tail -n 40 "/var/lib/dkms/$DRV/$VER/build/make.log" 2>/dev/null || true
  echo "-------------------------------------------------"
  die "La COMPILACION fallo en el kernel $KVER (driver incompatible con este kernel). rtl8xxxu sigue INTACTO y funcionando. Plan B: cambiar el dongle por uno MediaTek 5 GHz."
fi
dkms install -m "$DRV" -v "$VER" || die "dkms install fallo. rtl8xxxu sigue INTACTO."
dkms status | grep -q "${DRV}/${VER}" || die "El modulo no quedo instalado. rtl8xxxu sigue INTACTO."
log "Driver $DRV compilado e instalado. AHORA hago el cambio (a partir de aqui, con rollback automatico)."

# --- 3) Opciones de estabilidad + desactivar el generico ----------------------
cat >/etc/modprobe.d/8188eu.conf <<'EOF'
options 8188eu rtw_power_mgnt=0 rtw_enusbss=0 rtw_ips_mode=0
EOF
cat >/etc/modprobe.d/blacklist-rtl8xxxu.conf <<'EOF'
blacklist rtl8xxxu
EOF
update-initramfs -u >/dev/null 2>&1 || true

# --- 4) Cambio en caliente CON red de seguridad -------------------------------
log "Cambiando al driver 8188eu..."
modprobe -r rtl8xxxu 2>/dev/null || true
modprobe 8188eu 2>/dev/null || true
sleep 8
NEWIFACE="$(ls /sys/class/net 2>/dev/null | grep -E '^wlx' | head -n1 || true)"

if [ -z "$NEWIFACE" ]; then
  log "!! La interfaz NO reaparecio. Reintento tras reiniciar udev..."
  udevadm control --reload 2>/dev/null || true; udevadm trigger 2>/dev/null || true
  sleep 6
  NEWIFACE="$(ls /sys/class/net 2>/dev/null | grep -E '^wlx' | head -n1 || true)"
fi

if [ -z "$NEWIFACE" ]; then
  log "!! Sigue sin aparecer. REVIRTIENDO al driver original para no dejarte sin red..."
  rm -f /etc/modprobe.d/blacklist-rtl8xxxu.conf /etc/modprobe.d/8188eu.conf
  echo "blacklist 8188eu" >/etc/modprobe.d/blacklist-8188eu.conf   # evitar conflicto
  update-initramfs -u >/dev/null 2>&1 || true
  modprobe -r 8188eu 2>/dev/null || true
  modprobe rtl8xxxu 2>/dev/null || true
  sleep 6
  die "Revertido a rtl8xxxu. El 8188eu quedo compilado pero no levanto en caliente. PRUEBA A REINICIAR el equipo (a veces solo arranca limpio tras reboot): al reiniciar, borra /etc/modprobe.d/blacklist-8188eu.conf y crea /etc/modprobe.d/blacklist-rtl8xxxu.conf con 'blacklist rtl8xxxu'. Si tras reiniciar tampoco va, cambia el dongle."
fi
log "OK. Interfaz activa con el nuevo driver: $NEWIFACE"
IFACE="$NEWIFACE"

# --- 5) Endurecimiento (complementa las opciones del driver) ------------------
log "Aplicando endurecimiento..."
install -d /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/wifi-powersave-off.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF

# autosuspend USB off (por idVendor:idProduct del dongle)
USBDIR="$(readlink -f "/sys/class/net/$IFACE/device" 2>/dev/null || true)"
while [ -n "$USBDIR" ] && [ "$USBDIR" != "/" ] && [ ! -f "$USBDIR/idVendor" ]; do USBDIR="$(dirname "$USBDIR")"; done
if [ -n "${USBDIR:-}" ] && [ -f "$USBDIR/idVendor" ]; then
  VID="$(cat "$USBDIR/idVendor")"; PID="$(cat "$USBDIR/idProduct")"
  cat >/etc/udev/rules.d/50-usb-wifi-no-suspend.rules <<EOF
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="$VID", ATTR{idProduct}=="$PID", TEST=="power/control", ATTR{power/control}="on"
EOF
  echo on > "$USBDIR/power/control" 2>/dev/null || true
fi

# conexion permanente
sleep 4
CON="$(nmcli -t -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)"
if [ -n "$CON" ] && [ "$CON" != "--" ]; then
  nmcli connection modify "$CON" \
    connection.autoconnect yes connection.autoconnect-priority 999 \
    connection.autoconnect-retries 0 connection.permissions "" \
    802-11-wireless.powersave 2
  FILE="/etc/NetworkManager/system-connections/${CON}.nmconnection"
  [ -f "$FILE" ] && chown root:root "$FILE" && chmod 600 "$FILE"
  log "Conexion '$CON' fijada como permanente."
else
  log "Nota: aun sin conexion activa en $IFACE; en cuanto asocie a la wifi quedara con autoconnect."
fi

# bloqueo polkit para usuarios no admin
PKRAW="$(pkaction --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || echo 0)"
USE_JS=0
if printf '%s' "$PKRAW" | grep -q '\.'; then
  MAJ="${PKRAW%%.*}"; MIN="${PKRAW#*.}"; { [ "${MAJ:-0}" -gt 0 ] || [ "${MIN:-0}" -ge 106 ]; } && USE_JS=1
else
  [ "${PKRAW:-0}" -ge 106 ] && USE_JS=1
fi
if [ "$USE_JS" -eq 1 ]; then
  install -d /etc/polkit-1/rules.d
  cat >/etc/polkit-1/rules.d/90-lock-network.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 &&
        !subject.isInGroup("sudo")) { return polkit.Result.AUTH_ADMIN; }
});
EOF
else
  install -d /etc/polkit-1/localauthority/50-local.d
  cat >/etc/polkit-1/localauthority/50-local.d/90-lock-network.pkla <<'EOF'
[Proteger la red - requiere admin]
Identity=unix-user:*
Action=org.freedesktop.NetworkManager.enable-disable-wifi;org.freedesktop.NetworkManager.enable-disable-network;org.freedesktop.NetworkManager.network-control;org.freedesktop.NetworkManager.settings.modify.system;org.freedesktop.NetworkManager.settings.modify.own
ResultAny=auth_admin
ResultInactive=auth_admin
ResultActive=auth_admin
EOF
fi

udevadm control --reload 2>/dev/null || true; udevadm trigger 2>/dev/null || true
systemctl restart polkit 2>/dev/null || systemctl restart polkitd 2>/dev/null || true
systemctl restart NetworkManager
sleep 6

# --- 6) Verificacion ----------------------------------------------------------
echo
echo "==================== VERIFICACION ===================="
echo "-- Driver en uso:"; basename "$(readlink -f /sys/class/net/$IFACE/device/driver 2>/dev/null)" 2>/dev/null || true
echo "-- /proc/net/wireless (mira 'Missed beacon', debe crecer poco):"; cat /proc/net/wireless || true
GW="$(ip route | awk '/default/{print $3; exit}')"
echo "-- Ping al router (${GW:-desconocido}):"
[ -n "${GW:-}" ] && ping -c8 "$GW" || echo "   (sin ruta por defecto todavia)"
echo "======================================================"
echo "Si el ping al router va estable, listo. Reinicia UNA vez para confirmar que arranca con 8188eu."
echo "Para revertir todo:  sudo rm -f /etc/modprobe.d/blacklist-rtl8xxxu.conf /etc/modprobe.d/8188eu.conf ; sudo dkms remove ${DRV}/${VER} --all ; sudo update-initramfs -u ; reiniciar."
