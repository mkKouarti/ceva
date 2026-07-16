#!/usr/bin/env bash
#
# force-spanish-global.sh
# Makes Spanish (es) the keyboard layout for EVERY user on the machine,
# including users that don't exist yet, and LOCKS it so it can't drift back.
#
# Run:  sudo bash force-spanish-global.sh
#
set -euo pipefail

LAYOUT="es"          # use "latam" if the scanners are Latin-American Spanish
MODEL="pc105"
LOCALE="es_ES.UTF-8"

if [[ $EUID -ne 0 ]]; then
  echo "!! Run with sudo:  sudo bash force-spanish-global.sh" >&2
  exit 1
fi

echo ">>> 1) System console + X11 layout (global)"
cat > /etc/default/keyboard <<EOF
XKBMODEL="${MODEL}"
XKBLAYOUT="${LAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
command -v localectl >/dev/null 2>&1 && {
  localectl set-x11-keymap "${LAYOUT}" "${MODEL}" "" || true
  localectl set-keymap "${LAYOUT}" || true
}
command -v setupcon >/dev/null 2>&1 && setupcon --force || true

echo ">>> 2) System locale (global)"
command -v update-locale >/dev/null 2>&1 && update-locale LANG="${LOCALE}" LC_ALL="${LOCALE}" || true

echo ">>> 3) GNOME/dconf default for ALL users (this is the part that was missing)"
# dconf system database: a default that every user inherits, plus a lock.
install -d /etc/dconf/profile
if [[ ! -f /etc/dconf/profile/user ]]; then
  printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
else
  grep -q '^system-db:local' /etc/dconf/profile/user || echo 'system-db:local' >> /etc/dconf/profile/user
fi

install -d /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-keyboard <<EOF
[org/gnome/desktop/input-sources]
sources=[('xkb','${LAYOUT}')]
mru-sources=[('xkb','${LAYOUT}')]
xkb-options=@as []
EOF

# Lock it so no user (or stray setting) can switch it back.
install -d /etc/dconf/db/local.d/locks
cat > /etc/dconf/db/local.d/locks/00-keyboard <<EOF
/org/gnome/desktop/input-sources/sources
/org/gnome/desktop/input-sources/mru-sources
EOF

dconf update

echo ">>> 4) Apply to every EXISTING user's live gsettings too (belt and suspenders)"
# Covers anyone currently logged in, for all real users with a home dir.
while IFS=: read -r uname _ uid _ _ home _; do
  if [[ "${uid}" -ge 1000 && "${uid}" -ne 65534 && -d "${home}" ]]; then
    busdir="/run/user/${uid}/bus"
    if [[ -S "${busdir}" ]]; then
      echo "   applying to live session: ${uname} (uid ${uid})"
      sudo -u "${uname}" DBUS_SESSION_BUS_ADDRESS="unix:path=${busdir}" \
        gsettings set org.gnome.desktop.input-sources sources "[('xkb','${LAYOUT}')]" 2>/dev/null || true
    fi
  fi
done < /etc/passwd

echo
echo "==================== RESULT ===================="
grep -E 'XKBLAYOUT|XKBMODEL' /etc/default/keyboard | sed 's/^/   /'
command -v localectl >/dev/null 2>&1 && localectl status | sed 's/^/   /'
echo "   dconf default: $(cat /etc/dconf/db/local.d/00-keyboard | tr '\n' ' ')"
echo "================================================"
echo ">>> Done. This now applies to ALL users, including future ones, and is locked."
echo ">>> Log out / reboot, then scan into a text editor: expect wsMULTI_HZ0213 with no '((('."
