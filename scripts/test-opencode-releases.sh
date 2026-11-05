#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

repo_dir=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
if [[ ! -d "$tmp_base" || ! -w "$tmp_base" ]]; then
  tmp_base=/tmp
fi
[[ -d "$tmp_base" && -w "$tmp_base" ]] || {
  printf 'No hay un temporal escribible en TMPDIR, PREFIX/tmp o /tmp.\n' >&2
  exit 1
}

test_root=$(mktemp -d "$tmp_base/opencode-releases-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Test release_select_from_page logic using registry/lib/releases.sh
# shellcheck source=registry/lib/releases.sh
source "$repo_dir/registry/lib/releases.sh"

cat > "$test_root/page1.json" <<'EOF'
[
  {
    "tag_name": "process-daemon-0.1.0",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "opencode-linux-arm64.tar.gz", "digest": "sha256:111", "browser_download_url": "https://example/1"},
      {"name": "opencode-linux-amd64.tar.gz", "digest": "sha256:111", "browser_download_url": "https://example/1"}
    ]
  },
  {
    "tag_name": "v1.19.5",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "opencode-linux-arm64.tar.gz", "digest": "sha256:222", "browser_download_url": "https://example/2"},
      {"name": "opencode-linux-amd64.tar.gz", "digest": "sha256:222", "browser_download_url": "https://example/2"}
    ]
  },
  {
    "tag_name": "v2.2.6-alpha.1",
    "draft": false,
    "prerelease": true,
    "assets": [
      {"name": "opencode-linux-arm64.tar.gz", "digest": "sha256:333", "browser_download_url": "https://example/3"},
      {"name": "opencode-linux-amd64.tar.gz", "digest": "sha256:333", "browser_download_url": "https://example/3"}
    ]
  },
  {
    "tag_name": "v2.2.6-rc.2",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "opencode-linux-arm64.tar.gz", "digest": "sha256:444", "browser_download_url": "https://example/4"},
      {"name": "opencode-linux-amd64.tar.gz", "digest": "sha256:444", "browser_download_url": "https://example/4"}
    ]
  }
]
EOF

cat > "$test_root/page2.json" <<'EOF'
[
  {
    "tag_name": "v2.2.5+android1",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "opencode-linux-arm64.tar.gz", "digest": "sha256:555", "browser_download_url": "https://github.com/anomalyco/opencode/releases/download/v2.2.5+android1/opencode-linux-arm64.tar.gz"},
      {"name": "opencode-linux-amd64.tar.gz", "digest": "sha256:555", "browser_download_url": "https://github.com/anomalyco/opencode/releases/download/v2.2.5+android1/opencode-linux-amd64.tar.gz"}
    ]
  },
  {
    "tag_name": "v2.2.4",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "opencode-linux-arm64.tar.gz", "digest": "sha256:666", "browser_download_url": "https://example/6"},
      {"name": "opencode-linux-amd64.tar.gz", "digest": "sha256:666", "browser_download_url": "https://example/6"}
    ]
  }
]
EOF

# Page 1 must return empty for major=2 stable
p1_match=$(release_select_from_page "opencode-linux-arm64.tar.gz" "2" "stable" < "$test_root/page1.json")
[[ -z "$p1_match" ]] || fail 'page1 should not match any v2 stable release'

# Page 2 must match v2.2.5+android1 and preserve +build
p2_match=$(release_select_from_page "opencode-linux-arm64.tar.gz" "2" "stable" < "$test_root/page2.json")
[[ -n "$p2_match" ]] || fail 'page2 should match v2.2.5+android1'
p2_tag=$(printf '%s' "$p2_match" | jq -r '.tag_name')
[[ "$p2_tag" == "v2.2.5+android1" ]] || fail "unexpected tag: $p2_tag"

printf 'PASS: release_select_from_page discards v1, prereleases, and preserves +build\n'

# 2. Test mock multi-page resolution with install.sh --resolve-version in isolated sandbox
mock_repo="$test_root/mock-repo"
mkdir -p "$mock_repo/registry/lib"
cp "$repo_dir/install.sh" "$mock_repo/install.sh"
cp "$repo_dir/registry/lib/releases.sh" "$mock_repo/registry/lib/releases.sh"
cp "$repo_dir/aicli" "$mock_repo/aicli"
touch "$mock_repo/sha256.txt"

cat > "$mock_repo/registry/opencode.conf" <<'EOF'
APP_NAME="opencode"
DISPLAY_NAME="OpenCode"
REPO="anomalyco/opencode"
VERSION_MAJOR="2"
RELEASE_CHANNEL="stable"
RELEASE_SOURCE="github"
CHECKSUM_ALGO="sha256"
CHECKSUM_SOURCE="release_digest"
ELF_NAME="opencode"
ARCHIVE_TEMPLATE="opencode-linux-{ARCH}.tar.gz"
DOWNLOAD_MAX_TIME=600
NEEDS_PATCHELF=false
EXEC_DIRECT=false
EOF

mock_bin_dir="$test_root/bin"
mkdir -p "$mock_bin_dir"

cat > "$mock_bin_dir/curl" <<EOF
#!/bin/sh
out_file=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -n "\$out_file" ]; then
  if [ ! -f "$test_root/page_counter" ]; then
    echo "1" > "$test_root/page_counter"
    cp "$test_root/page1.json" "\$out_file"
  else
    cnt=\$(cat "$test_root/page_counter")
    if [ "\$cnt" = "1" ]; then
      echo "2" > "$test_root/page_counter"
      cp "$test_root/page2.json" "\$out_file"
    else
      echo "[]" > "\$out_file"
    fi
  fi
  printf '200'
  exit 0
fi

echo "[]"
EOF
chmod 755 "$mock_bin_dir/curl"

# Test --resolve-version machine contract:
# - stdout must be EXACTLY "TARGET_VERSION=2.2.5+android1" and nothing else
# - exit code 0
if ! res_out=$(PATH="$mock_bin_dir:$PATH" bash "$mock_repo/install.sh" opencode --resolve-version 2>"$test_root/res.err"); then
  cat "$test_root/res.err" >&2
  fail "install.sh --resolve-version failed"
fi
[[ "$res_out" == "TARGET_VERSION=2.2.5+android1" ]] || fail "expected 'TARGET_VERSION=2.2.5+android1', got: '$res_out'"
[[ -s "$test_root/res.err" ]] || fail "expected logs in stderr, got empty stderr"

printf 'PASS: install.sh --resolve-version paginates and prints exact TARGET_VERSION on stdout\n'

# 3. Test incompatible flags with --resolve-version (must exit 2)
incompatible_flags=("-u" "-r" "--update" "-v 2.2.5" "--sha256 abc")
for flag in "${incompatible_flags[@]}"; do
  # shellcheck disable=SC2086
  if bash "$mock_repo/install.sh" opencode --resolve-version $flag >/dev/null 2>&1; then
    fail "expected exit code 2 for --resolve-version $flag, but command succeeded"
  else
    rc=$?
    [[ $rc -eq 2 ]] || fail "expected exit code 2 for --resolve-version $flag, got: $rc"
  fi
done

printf 'PASS: install.sh --resolve-version exits 2 on incompatible flags\n'

# 4. Test aicli list --json network failure degradation
cat > "$mock_bin_dir/curl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$mock_bin_dir/curl"

mkdir -p "$test_root/tmp"
list_out=$(PATH="$mock_bin_dir:$PATH" TMPDIR="$test_root/tmp" bash "$repo_dir/aicli" list --json 2>/dev/null) || fail "aicli list --json must not exit with error on network failure"
printf '%s' "$list_out" | jq -e '.tools[] | select(.name == "opencode") | .latest_version == null' >/dev/null || fail "latest_version should be null when network fails"

printf 'PASS: aicli list --json degrades gracefully on network failure\n'
