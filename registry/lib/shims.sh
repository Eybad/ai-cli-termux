# shellcheck shell=bash
# shellcheck disable=SC2154

tool_shims_reset() {
  local shims_file="$LIBEXEC_DIR/shims.txt"
  : > "$shims_file"
}

tool_browser_shims() {
  [[ -f "$LIBEXEC_DIR/shims.txt" ]] || return 1
  local shims_file="$LIBEXEC_DIR/shims.txt"
  local shim_marker="termux-shim: $APP_NAME"
  local browser shim
  for browser in xdg-open sensible-browser x-www-browser gnome-open kde-open wslview open; do
    shim="$PREFIX/bin/$browser"
    if [[ -e "$shim" || -L "$shim" ]]; then
      if [[ -f "$shim" ]] && grep -qF "$shim_marker" "$shim" 2>/dev/null; then
        printf '%s\n' "$browser" >> "$shims_file"
      elif [[ -f "$shim" ]] && [[ ! -L "$shim" ]] \
        && [[ $(wc -l < "$shim") -eq 2 ]] \
        && ! grep -qE 'termux-shim:' "$shim" 2>/dev/null \
        && grep -qxF '#!/data/data/com.termux/files/usr/bin/bash' "$shim" 2>/dev/null \
        && grep -qxF 'exec termux-open-url "$@"' "$shim" 2>/dev/null; then
        # Migrate legacy 2-line shims to explicit ownership marker.
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
        # Migrate legacy 2-line shims to explicit ownership marker.
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
