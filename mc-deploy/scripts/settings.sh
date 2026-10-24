# Sourced by the deploy/configure scripts. Checks a settings JSON object against
# settings-schema.json and prints one KEY=VALUE line per setting (KEY= means "unset it").
# Anything not in the schema, or out of range, is refused. That's what lets the panel
# send settings without being able to set arbitrary env vars on a server.

SETTINGS_SCHEMA="$(dirname "${BASH_SOURCE[0]}")/../settings-schema.json"

validate_settings() {   # validate_settings <java|bedrock> <json>
  local edition="$1" json="${2:-}"
  [ -n "$json" ] || json='{}'
  jq -r --arg ed "$edition" --slurpfile schema "$SETTINGS_SCHEMA" '
    def trim: gsub("^\\s+|\\s+$"; "");
    ($schema[0][$ed] // error("unknown edition \($ed)")) as $sch
    | if type != "object" then error("settings must be a JSON object") else . end
    | to_entries[]
    | .key as $k | (if .value == null then "" else .value end) as $v   # not //, which also eats false
    | ($sch[$k] // error("\($k) is not a setting you can change")) as $d
    | ($v | if type == "array" then map(tostring) | join(",") else tostring end | trim) as $t
    | (if $t == "" then ""
       elif $d.type == "enum" then (if ($d.values | index($t)) then $t else error("\($k) must be one of: \($d.values | join(", "))") end)
       elif $d.type == "bool" then (if ($t | test("^(true|false)$")) then $t else error("\($k) must be true or false") end)
       elif $d.type == "int" then (if ($t | test("^[0-9]+$")) and ($t | tonumber) >= $d.min and ($t | tonumber) <= $d.max then $t
                                  else error("\($k) must be a whole number from \($d.min) to \($d.max)") end)
       elif $d.type == "string" then (if ($t | length) <= ($d.max // 100) and ($t | test("^[^\\n\\r]*$"))
                                         and ($t | test($d.pattern // ".*")) then $t else error("\($k) is not allowed: \($t)") end)
       elif $d.type == "list" then ([$t | split(",")[] | trim | select(. != "")] as $items
                                    | if ($items | all(test($d.item))) then $items | join(",")
                                      else error("\($k): \($items | map(select(test($d.item) | not)) | join(", ")) is not a valid name") end)
       else error("bad schema entry for \($k)") end) as $out
    | "\($k)=\($out)"' <<< "$json"
}
