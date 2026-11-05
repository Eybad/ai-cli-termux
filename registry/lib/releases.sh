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
