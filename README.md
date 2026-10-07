# Laneter

Cliente de terminal para LANE, construido sobre LaneTK.

- PTY: forkpty (libutil/libc).
- Parser VT: libvterm 0.3.3.
- Rendering: cairo + pango.
- Integración: Server/Window de LaneTK (poll loop).

## Uso

    ./run app.lua

## Instalación

    sudo tools/install.sh -y

Instala en `/opt/laneter`.

## Dependencias

- LaneTK (con `lib.terminal.pty` y `lib.terminal.vterm`).
- `libvterm.so.0` (Void: `libvterm`).
- `libutil.so.1` (glibc, provee `forkpty`).

## Fases

- F1: PTY + libvterm + render mínimo (echo end-to-end).
- F2: resize + alt screen + 256 colores (vim, htop, less).
- F3: scrollback + selección + copy/paste + mouse.
- F4: performance + OSC título + truecolor.
