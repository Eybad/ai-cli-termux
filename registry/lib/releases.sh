# shellcheck shell=sh

release_policy_fields_valid() {
  printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)$' || [ -z "$1" ] || return 1
  case "$2" in
    ''|stable) return 0 ;;
    *) return 1 ;;
  esac
}

release_version_major() {
  printf '%s\n' "$1" | sed -nE 's/^v?([0-9]+)[.][0-9]+[.][0-9]+([-+].*)?$/\1/p'
}

release_version_is_stable() {
  printf '%s\n' "$1" | grep -Eq '^v?[0-9]+[.][0-9]+[.][0-9]+([+][0-9A-Za-z.-]+)?$'
}

release_select_from_page() {
  jq -c --arg asset "$1" --arg major "$2" --arg channel "$3" '
    def valid_tag($tag):
      ($tag | type) == "string" and
      ($tag | test("^v?[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?$"));

    if type != "array" then error("release response is not an array") else . end
    | [
        .[]
        | select(type == "object")
        | select(($major == "" and $channel == "") or valid_tag(.tag_name))
        | select($major == "" or ((.tag_name | capture("^v?(?<major>[0-9]+)[.]").major) == $major))
        | select(
            $channel != "stable" or
            (.draft == false and .prerelease == false and
              (.tag_name | test("^v?[0-9]+[.][0-9]+[.][0-9]+([+][0-9A-Za-z.-]+)?$")))
          )
        | select((.assets // []) | type == "array")
        | . as $release
        | [($release.assets // [])[] | select(.name == $asset)] as $matches
        | if ($matches | length) > 1 then error("release contains duplicate asset names")
          elif ($matches | length) == 1 then $release
          else empty
          end
      ][0] // empty
  '
}

release_validate_object() {
  printf '%s' "$1" | jq -e --arg asset "$2" --arg major "$3" --arg channel "$4" --arg tag "$5" '
    def valid_tag($value):
      ($value | type) == "string" and
      ($value | test("^v?[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?$"));

    if type != "object" or .tag_name != $tag or (valid_tag(.tag_name) | not) then false
    else
      ((.assets | type) == "array") and
      ([.assets[] | select(.name == $asset)] | length) == 1 and
      ($major == "" or (.tag_name | capture("^v?(?<major>[0-9]+)[.]").major) == $major) and
      ($channel != "stable" or
        (.draft == false and .prerelease == false and
          (.tag_name | test("^v?[0-9]+[.][0-9]+[.][0-9]+([+][0-9A-Za-z.-]+)?$"))))
    end
  ' >/dev/null
}

release_asset_url() {
  jq -er --arg asset "$1" --arg expected "$2" '
    if type != "object" or (.assets | type) != "array" then error("release assets are malformed")
    else
      [.assets[] | select(.name == $asset)] as $matches
      | if ($matches | length) != 1 then error("release asset is missing or ambiguous")
        elif $matches[0].browser_download_url != $expected then error("release asset URL does not match its tag")
        else $matches[0].browser_download_url
        end
    end
  '
}

release_asset_digest() {
  jq -er --arg asset "$1" '
    if type != "object" or (.assets | type) != "array" then error("release assets are malformed")
    else
      [.assets[] | select(.name == $asset)] as $matches
      | if ($matches | length) != 1 then error("release asset is missing or ambiguous")
        elif ($matches[0].digest | type) != "string" then error("release asset digest is missing")
        else $matches[0].digest
        end
    end
  '
}

release_contract_supported() {
  case "$1" in
    termux-glibc-1) return 0 ;;
    *) return 1 ;;
  esac
}

release_catalog_validate() (
  catalog_file="$1"
  expected_app="$2"
  expected_major="$3"
  release_catalog_repo_root="$4"
  jq -e \
    --arg app "$expected_app" \
    --arg major "$expected_major" '
    def valid_tag($tag):
      ($tag | type) == "string" and
      ($tag | test("^v?(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)([+][0-9A-Za-z-]+([.][0-9A-Za-z-]+)*)?$"));
    def valid_asset($asset):
      ($asset | type) == "object" and
      ($asset.name | type) == "string" and
      ($asset.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      ($asset.sha256 | type) == "string" and
      ($asset.sha256 | test("^[a-f0-9]{64}$")) and
      ($asset.evidence | type) == "string" and
      ($asset.evidence | startswith("docs/compatibility/")) and
      ($asset.evidence | split("/") | all(.[]; . != "" and . != "." and . != ".."));
    def valid_release($release):
      ($release | type) == "object" and
      ($release.sequence | type) == "number" and
      ($release.sequence | floor == . and . > 0) and
      valid_tag($release.tag) and
      ($release.tag | capture("^v?(?<major>0|[1-9][0-9]*)[.]").major) == $major and
      ($release.source_commit | type) == "string" and
      ($release.source_commit | test("^[a-f0-9]{40}$")) and
      ($release.contract | type) == "string" and
      ($release.assets | type) == "object" and
      ($release.assets | length) > 0 and
      ($release.assets | to_entries | all(.[];
        (.key == "arm64" or .key == "amd64") and valid_asset(.value)
      ));
    . as $catalog
    | ($catalog | type) == "object" and
      $catalog.schema == 1 and
      $catalog.app == $app and
      ($catalog.preferred | type) == "object" and
      ($catalog.releases | type) == "array" and
      ($catalog.releases | all(.[]; valid_release(.))) and
      ([ $catalog.releases[].tag | sub("^v"; "") ] | unique | length) == ($catalog.releases | length) and
      ([ $catalog.releases[].sequence ] | unique | length) == ($catalog.releases | length) and
      ([ $catalog.releases[].sequence ] == ([ $catalog.releases[].sequence ] | sort)) and
      ([ $catalog.releases[].tag | sub("^v"; "") | split("+")[0] | split(".") | map(tonumber) ] as $cores
        | all(range(1; ($cores | length)); . as $index | $cores[$index] >= $cores[$index - 1])) and
      (($catalog.preferred | keys | all(.[]; . == "arm64" or . == "amd64"))) and
      (if ($catalog.releases | length) == 0 then
         ($catalog.preferred | length) == 0
       else
         ($catalog.preferred | length) > 0 and
         all(($catalog.preferred | to_entries[]); . as $selected |
           any($catalog.releases[]; .tag == $selected.value and (.assets | has($selected.key))) and
           ([$catalog.releases[] | select(.assets | has($selected.key))] | max_by(.sequence).tag) == $selected.value
         )
       end)
  ' "$catalog_file" >/dev/null 2>&1 || return 1

  catalog_contracts=$(jq -r '.releases[].contract' "$catalog_file") || return 1
  while IFS= read -r catalog_contract; do
    [ -z "$catalog_contract" ] && continue
    release_contract_supported "$catalog_contract" || return 1
  done <<EOF
$catalog_contracts
EOF

  evidence_paths=$(jq -r '.releases[].assets[] | .evidence' "$catalog_file") || return 1
  while IFS= read -r evidence; do
    [ -z "$evidence" ] && continue
    [ -f "$release_catalog_repo_root/$evidence" ] || return 1
  done <<EOF
$evidence_paths
EOF
)

release_catalog_preferred_tag() {
  jq -er --arg arch "$2" '.preferred[$arch] // empty' "$1"
}

release_catalog_entry_by_version() {
  jq -ce --arg version "$2" \
    '.releases[] | select((.tag | sub("^v"; "")) == $version)' "$1"
}

release_catalog_entry_by_tag() {
  jq -ce --arg tag "$2" '.releases[] | select(.tag == $tag)' "$1"
}

release_catalog_asset() {
  jq -ce --arg tag "$2" --arg arch "$3" \
    '.releases[] | select(.tag == $tag) | .assets[$arch] // empty' "$1"
}
