# registry/lib/shims.sh — Helpers compartidos de pre_wrapper_hook
#
# Sourceado por los hooks de registry/*.conf (codex, agy, cursor-agent):
#
#   source "$SCRIPT_DIR/registry/lib/shims.sh"
#
# dentro de pre_wrapper_hook() (install.sh provee PREFIX, LIBEXEC_DIR,
# APP_NAME y SCRIPT_DIR en scope al ejecutar el hook).
#
# Contrato (no romper):
#   - UNA sola llamada a tool_shims_reset() por corrida, ANTES de cualquier
#     tool_*_shims(). Reconstruye $LIBEXEC_DIR/shims.txt desde cero; cada
#     tool_*_shims() es append-only y re-registra los shims propios de
#     corridas anteriores (sin re-registro, un reinstall dejaría el registro
#     incompleto → el uninstall dejaría shims huérfanos).
#   - Fail-safe del contrato: tool_*_shims() aborta (return 1; con set -e del
#     instalador aborta la corrida) si shims.txt no existe — señal de reset
#     omitido o llamadas en orden incorrecto.
#   - Ownership: cada shim lleva el marcador "# termux-shim: $APP_NAME".
#     Herramientas comparten nombres de navegador; sin el marcador específico
#     el registro/borrado de un tool pisaría los shims del otro.
#   - Migración pre-ownership: un shim viejo se re-escribe SOLO si es
#     exactamente la forma antigua — archivo regular (no symlink) con
#     exactamente 2 líneas (shebang + línea exec, sin marcador ajeno). Un
#     shim de otro tool, un archivo del usuario con líneas extra o un
#     symlink no se tocan.
#   - Guardias FIFO-safe: [[ -f ]] antes de cualquier grep (un FIFO ajeno
#     colgaría el grep esperando datos).
#
# Los globals PREFIX/LIBEXEC_DIR/APP_NAME los provee install.sh al ejecutar
# el hook; no se asignan acá.
#
# shellcheck shell=bash
# shellcheck disable=SC2154  # PREFIX/LIBEXEC_DIR/APP_NAME: provistas por install.sh

# Reset del registro de shims de la corrida (shims.txt completo desde cero).
tool_shims_reset() {
  local shims_file="$LIBEXEC_DIR/shims.txt"
  : > "$shims_file"
}

# Shims de navegadores → termux-open-url (flujo OAuth de login).
# Fail-closed: si el nombre ya existe (ejecutable o no, incluso un symlink
# colgante), no se pisa — podría ser un archivo del usuario o de otro paquete.
tool_browser_shims() {
  [[ -f "$LIBEXEC_DIR/shims.txt" ]] || return 1
  local shims_file="$LIBEXEC_DIR/shims.txt"
  local shim_marker="termux-shim: $APP_NAME"
  local browser shim
  for browser in xdg-open sensible-browser x-www-browser gnome-open kde-open wslview open; do
    shim="$PREFIX/bin/$browser"
    if [[ -e "$shim" || -L "$shim" ]]; then
      # Re-registrar un shim propio de una corrida anterior (shims.txt se
      # reconstruye en cada corrida con tool_shims_reset). Solo shims con
      # NUESTRO marcador: un shim del otro tool o un archivo ajeno no se
      # registra ni se toca.
      if [[ -f "$shim" ]] && grep -qF "$shim_marker" "$shim" 2>/dev/null; then
        printf '%s\n' "$browser" >> "$shims_file"
      elif [[ -f "$shim" ]] && [[ ! -L "$shim" ]] \
        && [[ $(wc -l < "$shim") -eq 2 ]] \
        && ! grep -qE 'termux-shim:' "$shim" 2>/dev/null \
        && grep -qxF '#!/data/data/com.termux/files/usr/bin/bash' "$shim" 2>/dev/null \
        && grep -qxF 'exec termux-open-url "$@"' "$shim" 2>/dev/null; then
        # Marcador viejo (pre-ownership): es exactamente nuestro shim antiguo
        # (shebang + exec, sin marcador ajeno) — migrar al marcador específico.
        printf '#!/data/data/com.termux/files/usr/bin/bash\nexec termux-open-url "$@"\n# %s\n' "$shim_marker" > "$shim"
        chmod 755 "$shim"
        printf '%s\n' "$browser" >> "$shims_file"
      fi
      continue
    fi
    printf '#!/data/data/com.termux/files/usr/bin/bash\nexec termux-open-url "$@"\n# %s\n' "$shim_marker" > "$shim"
    chmod 755 "$shim"
    printf '%s\n' "$browser" >> "$shims_file"
  done
}

# Shims de portapapeles: redirigen stdin a termux-clipboard-set o /dev/null.
# Mismo esquema de ownership/migración/guardias que tool_browser_shims.
tool_clipboard_shims() {
  [[ -f "$LIBEXEC_DIR/shims.txt" ]] || return 1
  local shims_file="$LIBEXEC_DIR/shims.txt"
  local shim_marker="termux-shim: $APP_NAME"
  local clip shim
  for clip in xclip xsel pbcopy wl-copy; do
    shim="$PREFIX/bin/$clip"
    if [[ -e "$shim" || -L "$shim" ]]; then
      if [[ -f "$shim" ]] && grep -qF "$shim_marker" "$shim" 2>/dev/null; then
        printf '%s\n' "$clip" >> "$shims_file"
      elif [[ -f "$shim" ]] && [[ ! -L "$shim" ]] \
        && [[ $(wc -l < "$shim") -eq 2 ]] \
        && ! grep -qE 'termux-shim:' "$shim" 2>/dev/null \
        && grep -qxF '#!/data/data/com.termux/files/usr/bin/bash' "$shim" 2>/dev/null \
        && grep -qxF 'if command -v termux-clipboard-set >/dev/null; then exec termux-clipboard-set; else cat > /dev/null; fi' "$shim" 2>/dev/null; then
        # Marcador viejo (pre-ownership): es exactamente nuestro shim antiguo
        # (shebang + exec, sin marcador ajeno) — migrar al marcador específico.
        printf '#!/data/data/com.termux/files/usr/bin/bash\nif command -v termux-clipboard-set >/dev/null; then exec termux-clipboard-set; else cat > /dev/null; fi\n# %s\n' "$shim_marker" > "$shim"
        chmod 755 "$shim"
        printf '%s\n' "$clip" >> "$shims_file"
      fi
      continue
    fi
    printf '#!/data/data/com.termux/files/usr/bin/bash\nif command -v termux-clipboard-set >/dev/null; then exec termux-clipboard-set; else cat > /dev/null; fi\n# %s\n' "$shim_marker" > "$shim"
    chmod 755 "$shim"
    printf '%s\n' "$clip" >> "$shims_file"
  done
}
