#!/bin/sh
set -e
AUTO_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) AUTO_YES=1 ;;
        -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
        *) echo "arg desconocido: $1" >&2; exit 1 ;;
    esac
    shift
done
if [ -n "${SUDO_USER:-}" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_HOME="$HOME"
fi
SRC="${REAL_HOME}/proyectos/laneter"
DST="/opt/laneter"
if [ "$(id -u)" -ne 0 ]; then echo "necesita root"; exit 1; fi
if [ ! -f "$SRC/app.lua" ]; then echo "falta $SRC/app.lua"; exit 1; fi
if [ ! -d "/opt/lanetk/src/lib" ]; then echo "falta LaneTK"; exit 1; fi
if [ -d "$DST" ] && [ "$AUTO_YES" -eq 0 ]; then
    printf "==> Reemplazar $DST? [y/N] "
    read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) echo "Cancelado."; exit 0 ;; esac
fi
echo "==> laneter — instalación en $DST"
rm -rf "$DST"; mkdir -p "$DST"
tar -C "$SRC" --exclude='./.git' --exclude='*.bak' --exclude='*.bak-*' \
    --exclude='*.orig' --exclude='*.swp' --exclude='.DS_Store' \
    -cf - . | tar -C "$DST" -xf -
chmod -R a+rX,go-w "$DST"
chmod +x "$DST/run"
[ -f "$DST/tools/install.sh" ] && chmod +x "$DST/tools/install.sh"
cd "$DST"
if ./run -e 'print("requires OK")' 2>&1; then
    echo "    OK"
else
    echo "    FALLO" >&2; exit 1
fi

# Instalar el .desktop en el home del usuario real (el que invoco
# sudo, no root).
DESKTOP_DIR="$REAL_HOME/.local/share/applications"
if [ -f "$DST/assets/laneter.desktop" ]; then
    mkdir -p "$DESKTOP_DIR"
    cp "$DST/assets/laneter.desktop" "$DESKTOP_DIR/laneter.desktop"
    chown "$(id -u "${SUDO_USER:-$USER}"):$(id -g "${SUDO_USER:-$USER}" 2>/dev/null || echo "$(id -g)")" \
        "$DESKTOP_DIR/laneter.desktop" 2>/dev/null || true
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
    fi
    echo "==> .desktop instalado en $DESKTOP_DIR/laneter.desktop"
fi

echo "==> Instalación completa. laneter en $DST"
