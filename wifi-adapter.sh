#!/usr/bin/env bash
#
# harden-usb-wifi.sh
# Deja el dongle USB wifi estable, permanente y a prueba de manazas.
#   - Quita el power-save del wifi (NetworkManager)
#   - Quita el autosuspend USB del dongle concreto (udev)
#   - Fija la conexion: autoconnect, prioridad alta, reintentos infinitos, de sistema (root)
#   - Bloquea con polkit que un usuario normal apague/cambie la wifi
#   - Verifica al final
#
# Uso:  sudo ./harden-usb-wifi.sh
#
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Ejecutalo con sudo."; exit 1; }

echo "==> Detectando el dongle USB wifi (interfaz wlx*)..."
IFACE="$(ls /sys/class/net 2>/dev/null | grep -E '^wlx' | head -n1 || true)"
if [ -z "$IFACE" ]; then
  echo "!! No encuentro ninguna interfaz wifi USB (wlx*). ¿Esta enchufado el dongle?"
  exit 1
fi
echo "   Interfaz: $IFACE"

DRIVER="$(basename "$(readlink -f "/sys/class/net/$IFACE/device/driver" 2>/dev/null || echo desconocido)")"
echo "   Driver: $DRIVER"

# ----------------------------------------------------------------------
# 1) Power-save del wifi OFF (permanente, NetworkManager)
# ----------------------------------------------------------------------
echo "==> Desactivando power-save del wifi..."
install -d /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/wifi-powersave-off.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF

# ----------------------------------------------------------------------
# 2) Autosuspend USB del dongle OFF (permanente, udev por idVendor:idProduct)
# ----------------------------------------------------------------------
echo "==> Desactivando autosuspend USB del dongle..."
USBDIR="$(readlink -f "/sys/class/net/$IFACE/device" 2>/dev/null || true)"
while [ -n "$USBDIR" ] && [ "$USBDIR" != "/" ] && [ ! -f "$USBDIR/idVendor" ]; do
  USBDIR="$(dirname "$USBDIR")"
done
if [ -n "${USBDIR:-}" ] && [ -f "$USBDIR/idVendor" ]; then
  VID="$(cat "$USBDIR/idVendor")"; PID="$(cat "$USBDIR/idProduct")"
  cat >/etc/udev/rules.d/50-usb-wifi-no-suspend.rules <<EOF
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="$VID", ATTR{idProduct}=="$PID", TEST=="power/control", ATTR{power/control}="on"
EOF
  echo on > "$USBDIR/power/control" 2>/dev/null || true   # aplicar ya
  echo "   Regla creada para $VID:$PID"
else
  echo "   !! No pude sacar idVendor/idProduct; me salto el udev."
fi

# ----------------------------------------------------------------------
# 3) Conexion permanente y de sistema
# ----------------------------------------------------------------------
echo "==> Fijando la conexion como permanente..."
CON="$(nmcli -t -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)"
if [ -n "$CON" ] && [ "$CON" != "--" ]; then
  nmcli connection modify "$CON" \
    connection.autoconnect yes \
    connection.autoconnect-priority 999 \
    connection.autoconnect-retries 0 \
    connection.permissions "" \
    802-11-wireless.powersave 2
  FILE="/etc/NetworkManager/system-connections/${CON}.nmconnection"
  [ -f "$FILE" ] && chown root:root "$FILE" && chmod 600 "$FILE"
  echo "   Conexion '$CON' fijada (autoconnect, prioridad 999, reintentos infinitos, root:600)."
else
  echo "   !! No hay conexion activa en $IFACE. Conectate una vez a la wifi y vuelve a lanzar el script."
fi

# ----------------------------------------------------------------------
# 4) Bloqueo polkit: solo admins (grupo sudo) tocan la red
# ----------------------------------------------------------------------
echo "==> Bloqueando control de red para usuarios normales..."
PKRAW="$(pkaction --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || echo 0)"
USE_JS=0
if printf '%s' "$PKRAW" | grep -q '\.'; then
  MAJ="${PKRAW%%.*}"; MIN="${PKRAW#*.}"
  { [ "${MAJ:-0}" -gt 0 ] || [ "${MIN:-0}" -ge 106 ]; } && USE_JS=1
else
  [ "${PKRAW:-0}" -ge 106 ] && USE_JS=1
fi

if [ "$USE_JS" -eq 1 ]; then
  install -d /etc/polkit-1/rules.d
  cat >/etc/polkit-1/rules.d/90-lock-network.rules <<'EOF'
// Cualquier accion de NetworkManager pide contrasena de admin si no eres del grupo sudo.
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 &&
        !subject.isInGroup("sudo")) {
        return polkit.Result.AUTH_ADMIN;
    }
});
EOF
  echo "   Regla polkit (formato JS) aplicada."
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
  echo "   Regla polkit (formato pkla) aplicada."
fi

# ----------------------------------------------------------------------
# 5) Aplicar y verificar
# ----------------------------------------------------------------------
echo "==> Aplicando cambios..."
udevadm control --reload && udevadm trigger || true
systemctl restart polkit 2>/dev/null || systemctl restart polkitd 2>/dev/null || true
systemctl restart NetworkManager
sleep 6

echo
echo "==================== VERIFICACION ===================="
echo "-- Power save (debe decir off):"
command -v iw >/dev/null && iw dev "$IFACE" get power_save || echo "   (instala 'iw' para verlo: apt install iw)"
echo "-- Señal / enlace:"
command -v iw >/dev/null && iw dev "$IFACE" link || true
echo "-- Prueba de red:"
ping -c4 -i0.3 8.8.8.8 || true
echo "======================================================"
echo "Listo. Si tras esto sigue con perdidas y la señal es peor de ~-70 dBm,"
echo "el problema es de cobertura (no de software): usa un alargador USB con"
echo "vision al punto de acceso o acerca el AP."
