#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

expected_tools="agy codex opencode"
actual_tools=$(cd "$repo_dir/registry" && find . -maxdepth 1 -name '*.conf' | sed -e 's|^\./||' -e 's|\.conf$||' | sort | tr '\n' ' ' | sed 's/ $//')

if [[ "$actual_tools" != "$expected_tools" ]]; then
  fail "Herramientas registradas no coinciden. Esperadas: '$expected_tools', obtenidas: '$actual_tools'"
fi
pass "Registro contiene únicamente las herramientas soportadas: $actual_tools"

deleted_tools=("kiro-cli" "cursor-agent" "copilot")
for t in "${deleted_tools[@]}"; do
  if "$repo_dir/aicli" verify "$t" >/dev/null 2>&1; then
    fail "aicli verify $t debería haber fallado"
  else
    rc=$?
    [[ $rc -eq 2 ]] || fail "aicli verify $t esperaba exit code 2, obtuvo $rc"
  fi

  if "$repo_dir/aicli" remove "$t" >/dev/null 2>&1; then
    fail "aicli remove $t debería haber fallado"
  else
    rc=$?
    [[ $rc -eq 2 ]] || fail "aicli remove $t esperaba exit code 2, obtuvo $rc"
  fi
done
pass "Herramientas eliminadas (kiro-cli, cursor-agent, copilot) son rechazadas con exit code 2"

for conf in "$repo_dir/registry"/*.conf; do
  tool_name=$(basename "$conf" .conf)

  for key in APP_NAME DISPLAY_NAME RELEASE_SOURCE CHECKSUM_ALGO CHECKSUM_SOURCE ELF_NAME; do
    val=$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/,""); gsub(/(^"|"$)/,""); print; exit }' "$conf")
    [[ -n "$val" ]] || fail "Tool $tool_name falta campo obligatorio: $key"
  done

  exec_direct=$(awk -F= '$1=="EXEC_DIRECT" { sub(/^[^=]*=/,""); gsub(/(^"|"$)/,""); print; exit }' "$conf")
  needs_patchelf=$(awk -F= '$1=="NEEDS_PATCHELF" { sub(/^[^=]*=/,""); gsub(/(^"|"$)/,""); print; exit }' "$conf")

  if [[ "$exec_direct" == "true" && "$needs_patchelf" == "true" ]]; then
    fail "Tool $tool_name viola invariante: EXEC_DIRECT=true no puede tener NEEDS_PATCHELF=true"
  fi
done
pass "Invariantes y campos obligatorios de .conf restantes validados"

bash_comp=$("$repo_dir/aicli" completion bash)
for t in "${deleted_tools[@]}"; do
  if printf '%s' "$bash_comp" | grep -qw "$t"; then
    fail "aicli completion bash expone herramienta eliminada: $t"
  fi
done
for t in agy codex opencode; do
  if ! printf '%s' "$bash_comp" | grep -qw "$t"; then
    fail "aicli completion bash no contiene herramienta esperada: $t"
  fi
done
pass "aicli completion expone únicamente las herramientas activas"

json_out=$("$repo_dir/aicli" list --offline --json)
tools_in_json=$(printf '%s' "$json_out" | jq -r '.tools[].name' | sort | tr '\n' ' ' | sed 's/ $//')
if [[ "$tools_in_json" != "$expected_tools" ]]; then
  fail "aicli list --json tools no coincide. Esperado: '$expected_tools', obtenido: '$tools_in_json'"
fi
pass "aicli list --json devuelve exactamente las herramientas esperadas"
