# shellcheck shell=bash
# shellcheck disable=SC2154

SHIM_SHARED_MARKER="termux-shim: ai-cli-termux"

tool_shims_reset() {
  local shims_file="$LIBEXEC_DIR/shims.txt"
  : > "$shims_file"
}

_write_termux_shim() {
  local shim="$1" body_line="$2"
  printf '#!/data/data/com.termux/files/usr/bin/bash\n%s\n# %s\n' "$body_line" "$SHIM_SHARED_MARKER" > "$shim"
  chmod 755 "$shim"
}

_ensure_termux_shim() {
  local name="$1" body_line="$2" shims_file="$3"
  local shim="$PREFIX/bin/$name"
  [[ -d "$PREFIX/bin" ]] || mkdir -p "$PREFIX/bin"
  if [[ -e "$shim" || -L "$shim" ]]; then
    [[ -f "$shim" && ! -L "$shim" ]] || return 0
    if grep -qF "$SHIM_SHARED_MARKER" "$shim" 2>/dev/null; then
      printf '%s\n' "$name" >> "$shims_file"
      return 0
    fi
    if grep -qE '^# termux-shim: [a-zA-Z0-9._-]+$' "$shim" 2>/dev/null; then
      _write_termux_shim "$shim" "$body_line"
      printf '%s\n' "$name" >> "$shims_file"
      return 0
    fi
    if [[ $(wc -l < "$shim") -eq 2 ]] \
      && ! grep -qF 'termux-shim:' "$shim" 2>/dev/null \
      && grep -qxF '#!/data/data/com.termux/files/usr/bin/bash' "$shim" 2>/dev/null \
      && grep -qxF "$body_line" "$shim" 2>/dev/null; then
      # Migrate legacy 2-line shims to the shared ownership marker.
      _write_termux_shim "$shim" "$body_line"
      printf '%s\n' "$name" >> "$shims_file"
    fi
    return 0
  fi
  _write_termux_shim "$shim" "$body_line"
  printf '%s\n' "$name" >> "$shims_file"
}

tool_browser_shims() {
  [[ -f "$LIBEXEC_DIR/shims.txt" ]] || return 1
  local shims_file="$LIBEXEC_DIR/shims.txt"
  local body_line='exec termux-open-url "$@"'
  local browser
  for browser in xdg-open sensible-browser x-www-browser gnome-open kde-open wslview open; do
    _ensure_termux_shim "$browser" "$body_line" "$shims_file"
  done
}

tool_clipboard_shims() {
  [[ -f "$LIBEXEC_DIR/shims.txt" ]] || return 1
  local shims_file="$LIBEXEC_DIR/shims.txt"
  local body_line='if command -v termux-clipboard-set >/dev/null; then exec termux-clipboard-set; else cat > /dev/null; fi'
  local clip
  for clip in xclip xsel pbcopy wl-copy; do
    _ensure_termux_shim "$clip" "$body_line" "$shims_file"
  done
}
