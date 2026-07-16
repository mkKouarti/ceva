#!/usr/bin/env bash
#
# set-spanish.sh
# Forces the keyboard layout (and locale) to Spanish (Spain) on Ubuntu,
# at EVERY layer, so a scanner configured for a Spanish keyboard stops
# emitting wrong characters (e.g. "((((" instead of digits).
#
# The layout is the real fix for the scanner. Locale (LANG) is cosmetic
# for the scanner but changed too because you asked for "absolutely everything".
#
# Run with:   sudo bash set-spanish.sh
#
set -euo pipefail

# ---- what we are setting ------------------------------------------------
LAYOUT="es"          # Spanish (Spain). Use "latam" for Latin-American Spanish.
VARIANT=""           # e.g. "nodeadkeys" or "deadtilde"; leave empty for default
MODEL="pc105"        # standard 105-key PC keyboard
LOCALE="es_ES.UTF-8" # system language/locale
# -------------------------------------------------------------------------

echo ">>> Target: layout=${LAYOUT} variant='${VARIANT}' model=${MODEL} locale=${LOCALE}"

# --- must be root for the system-wide bits -------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "!! Please run with sudo:  sudo bash set-spanish.sh" >&2
  exit 1
fi

# The desktop user (needed later for gsettings, which must NOT run as root)
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
echo ">>> Desktop user detected as: ${TARGET_USER:-<none>}"

# =========================================================================
# 1) CONSOLE + X11 default via /etc/default/keyboard  (the master file)
# =========================================================================
echo ">>> Writing /etc/default/keyboard"
cp -a /etc/default/keyboard "/etc/default/keyboard.bak.$(date +%s)" 2>/dev/null || true
cat > /etc/default/keyboard <<EOF
# Configured by set-spanish.sh
XKBMODEL="${MODEL}"
XKBLAYOUT="${LAYOUT}"
XKBVARIANT="${VARIANT}"
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# Apply to the text console immediately
if command -v setupcon >/dev/null 2>&1; then
  setupcon --force || echo "   (setupcon reported an issue, continuing)"
fi
if command -v loadkeys >/dev/null 2>&1; then
  loadkeys "${LAYOUT}" >/dev/null 2>&1 || true
fi

# =========================================================================
# 2) systemd (localectl) — sets both console and X11 keymaps system-wide
# =========================================================================
if command -v localectl >/dev/null 2>&1; then
  echo ">>> localectl set-x11-keymap / set-keymap"
  localectl set-x11-keymap "${LAYOUT}" "${MODEL}" "${VARIANT}" || true
  localectl set-keymap "${LAYOUT}" || true
fi

# =========================================================================
# 3) LOCALE / system language
# =========================================================================
echo ">>> Enabling and generating locale ${LOCALE}"
if command -v locale-gen >/dev/null 2>&1; then
  sed -i "s/^# *${LOCALE}/${LOCALE}/" /etc/locale.gen 2>/dev/null || true
  grep -q "^${LOCALE}" /etc/locale.gen 2>/dev/null || echo "${LOCALE} UTF-8" >> /etc/locale.gen
  locale-gen "${LOCALE}" || true
fi
if command -v update-locale >/dev/null 2>&1; then
  update-locale LANG="${LOCALE}" LC_ALL="${LOCALE}" || true
fi

# =========================================================================
# 4) CURRENT X11 SESSION (takes effect without logout, if on Xorg)
# =========================================================================
if [[ -n "${TARGET_USER}" ]]; then
  USER_ID="$(id -u "${TARGET_USER}" 2>/dev/null || echo "")"

  # setxkbmap for a live Xorg session
  if [[ -n "${USER_ID}" ]]; then
    echo ">>> Applying to live X session for ${TARGET_USER} (if Xorg)"
    sudo -u "${TARGET_USER}" DISPLAY=":0" setxkbmap "${LAYOUT}" "${VARIANT}" 2>/dev/null \
      && echo "   setxkbmap applied" \
      || echo "   (no live Xorg session, or on Wayland — GNOME step below handles it)"

    # =====================================================================
    # 5) GNOME input sources (Wayland AND Xorg GNOME desktops)
    #    Must run as the user with their DBus session.
    # =====================================================================
    echo ">>> Setting GNOME input source to ${LAYOUT} only"
    sudo -u "${TARGET_USER}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_ID}/bus" \
      gsettings set org.gnome.desktop.input-sources sources "[('xkb','${LAYOUT}')]" 2>/dev/null \
      && sudo -u "${TARGET_USER}" \
         DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_ID}/bus" \
         gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb','${LAYOUT}')]" 2>/dev/null \
      && echo "   GNOME input source set" \
      || echo "   (GNOME not in use or gsettings unavailable — safe to ignore)"
  fi
fi

# =========================================================================
# 6) VERIFY
# =========================================================================
echo
echo "==================== RESULT ===================="
echo "/etc/default/keyboard:"
grep -E 'XKBLAYOUT|XKBVARIANT|XKBMODEL' /etc/default/keyboard | sed 's/^/   /'
if command -v localectl >/dev/null 2>&1; then
  echo "localectl status:"
  localectl status | sed 's/^/   /'
fi
if [[ -n "${TARGET_USER:-}" ]]; then
  echo "Live X layout (if Xorg):"
  sudo -u "${TARGET_USER}" DISPLAY=":0" setxkbmap -query 2>/dev/null | sed 's/^/   /' \
    || echo "   (not on Xorg / no live session)"
fi
echo "================================================"
echo
echo ">>> Done. If the console/X layout didn't switch live, LOG OUT and back in"
echo "    (or reboot) to guarantee every layer is Spanish."
echo
echo ">>> TEST: open a text editor and scan the workstation barcode."
echo "    It should read  wsMULTI_HZ0213  with NO trailing '((((' characters."
