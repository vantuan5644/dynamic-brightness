#!/bin/bash
# Offline tests for bin/dynamic-brightness. hyprctl, wluma and systemctl are
# replaced by stubs on PATH, so nothing touches a real monitor or service.
#
#   tests/run.sh
#
# `check && ok || fail` is the idiom throughout; ok and fail always succeed,
# so the SC2015 caveat cannot bite.
# shellcheck disable=SC2015

set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLI=$HERE/../bin/dynamic-brightness
PASS=0 FAIL=0
ORIG_PATH=$PATH

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/        /'; }

# Three monitors laid out like the omarchy desk: two RTK panels stacked on the
# left (hex serials, one with an empty EDID model, hence "0x2775") and an LG.
monitors_fixture() {
  local top=${1:-DP-1}
  cat <<EOF
[
 {"name":"HDMI-A-1","description":"Invalid Vendor Codename - RTK J560J10 0x20240308","serial":"0x20240308","x":0,"y":1000,"scale":1.6,"width":2560,"height":1600,"disabled":false,"dpmsStatus":true},
 {"name":"$top","description":"Invalid Vendor Codename - RTK 0x2775 0x20230923","serial":"0x20230923","x":0,"y":0,"scale":1.6,"width":2560,"height":1600,"disabled":false,"dpmsStatus":true},
 {"name":"DP-2","description":"LG Electronics LG HDR 4K 0x00044DDB","serial":"0x00044DDB","x":1600,"y":280,"scale":1.5,"width":3840,"height":2160,"disabled":false,"dpmsStatus":true}
]
EOF
}

# Fresh sandbox: config/state dirs, stub binaries, and logs of what the stubs
# were asked to do. wluma's IPC answers from $T/wluma-status.json (empty file
# = daemon down); `set brightness` is logged and also written back into that
# file, so a later status read sees it as real wluma would.
setup() {
  T=$(mktemp -d)
  export XDG_CONFIG_HOME=$T/config XDG_STATE_HOME=$T/state
  export DYNAMIC_BRIGHTNESS_FOREGROUND=1 DYNAMIC_BRIGHTNESS_READY_TIMEOUT=1
  SETTINGS=$XDG_CONFIG_HOME/dynamic-brightness/settings.json
  WCONF=$XDG_CONFIG_HOME/wluma/config.toml
  mkdir -p "$T/bin"
  monitors_fixture >"$T/monitors.json"
  : >"$T/wluma-status.json"
  : >"$T/systemctl.log"; : >"$T/wluma.log"

  cat >"$T/bin/hyprctl" <<EOF
#!/bin/bash
cat "$T/monitors.json"
EOF
  cat >"$T/bin/wluma" <<EOF
#!/bin/bash
f="$T/wluma-status.json"
case "\$1" in
  status) [[ -s \$f ]] || exit 1; cat "\$f" ;;
  set)    # Real wluma rejects a bare number: "value must be a percentage".
          [[ \$4 =~ ^[0-9]+%\$ ]] || { echo "wluma: value must be a percentage from 0% to 100%" >&2; exit 2; }
          echo "\$*" >>"$T/wluma.log"
          [[ -s \$f ]] && jq --arg n "\$3" --argjson v "\${4%\%}" \
            '(.outputs[] | select(.name == \$n) | .brightness) = \$v' "\$f" >"\$f.tmp" && mv "\$f.tmp" "\$f" ;;
esac
EOF
  cat >"$T/bin/systemctl" <<EOF
#!/bin/bash
[[ "\$*" == *is-active* ]] && { [[ -e "$T/wluma-active" ]]; exit; }
echo "\$*" >>"$T/systemctl.log"
EOF
  chmod +x "$T/bin/"*
  export PATH=$T/bin:$ORIG_PATH
}

teardown() { rm -rf "$T"; }
run() { "$CLI" "$@" 2>"$T/stderr"; }

# wluma_shows <connector> <luma> <brightness>: what the running daemon reports.
wluma_shows() {
  printf '{"outputs":[{"name":"%s","luma":%s,"brightness":%s,"state":"active"}]}\n' "$1" "$2" "$3" >"$T/wluma-status.json"
}
last_set() { tail -n1 "$T/wluma.log"; }

echo "config with nothing enabled"
setup
out=$(run config)
[[ $out == "# Managed by dynamic-brightness"* ]] && ok "starts with the ownership marker" || fail "marker" "$out"
grep -q '^\[als.none\]' <<<"$out" && ok "ambient light disabled" || fail "als.none" "$out"
grep -A1 '^\[idle\]' <<<"$out" | grep -q 'enabled = false' && ok "wluma idle dimming off" || fail "idle" "$out"
[[ $(grep -c 'enabled = false' <<<"$out") == 4 ]] && ok "every monitor told to stay out (3 + idle)" || fail "disabled count" "$out"
grep -q 'predictor' <<<"$out" && fail "no predictor expected" "$out" || ok "no curve for disabled monitors"
teardown

echo "enable one monitor"
setup
run set "RTK 0x2775" on strength=50 || fail "set exited non-zero" "$(cat "$T/stderr")"
jq -e '.monitors["Invalid Vendor Codename - RTK 0x2775 0x20230923"] == {"enabled":true,"strength":50}' "$SETTINGS" >/dev/null &&
  ok "stored under the full description" || fail "settings" "$(cat "$SETTINGS")"
block=$(awk '/^name = "DP-1"/{f=1} f&&/^\[\[output\.(ddcutil|backlight)\]\]/{exit} f{print}' "$WCONF")
grep -q 'identifier = "0x20230923"' <<<"$block" && ok "DDC identifier is the lower-case serial" || fail "identifier" "$block"
grep -q 'gamma = false' <<<"$block" && ok "gamma left to the night light" || fail "gamma" "$block"
grep -A3 'luma = 100' <<<"$block" | grep -q 'reduction = 50' && ok "white reduction = strength" || fail "reduction" "$block"
grep -q 'restart wluma.service' "$T/systemctl.log" && ok "wluma restarted" || fail "restart" "$(cat "$T/systemctl.log")"
: >"$T/systemctl.log"; touch "$T/wluma-active"
run apply
[[ ! -s $T/systemctl.log ]] && ok "unchanged config leaves a running wluma alone" || fail "idempotent apply" "$(cat "$T/systemctl.log")"
teardown

echo "monitor lookup"
setup
run set RTK on && fail "ambiguous match accepted" || { grep -q 'more than one' "$T/stderr" && ok "ambiguous 'RTK' rejected"; }
run set nope on && fail "unknown monitor accepted" || ok "unknown monitor rejected"
run set DP-2 strength=95 && fail "strength 95 accepted" || ok "strength above 90 rejected"
run set DP-2 strength=abc && fail "non-numeric strength accepted" || ok "non-numeric strength rejected"
# "DP-1" is also a substring of nothing here, but an exact connector must win
# even when a description happens to contain it.
sed -i 's/"LG Electronics LG HDR 4K 0x00044DDB"/"LG HDR 4K for DP-1 users"/' "$T/monitors.json"
run set DP-1 on && ok "exact connector wins over a description substring" || fail "exact connector" "$(cat "$T/stderr")"
teardown

echo "concurrent sets"
setup
sed -i '2i sleep 0.3' "$T/bin/hyprctl"   # make the read-modify-writes overlap
run set HDMI-A-1 on strength=10 & run set DP-2 on strength=20 & wait
jq -e '[.monitors[] | .enabled] == [true, true]' "$SETTINGS" >/dev/null &&
  ok "neither change is lost" || fail "lost update" "$(cat "$SETTINGS")"
teardown

echo "connector renumbering"
setup
run set DP-1 on strength=30
monitors_fixture DP-3 >"$T/monitors.json"
cfg=$(run config)
grep -A3 '^name = "DP-3"' <<<"$cfg" | grep -q 'identifier' && ok "settings follow the panel to DP-3" || fail "renumber" "$cfg"
teardown

echo "keeping your brightness across restarts"
setup
# You set 40 with dark content up, then switch it on: base 40.
wluma_shows DP-1 0 40
run set DP-1 on strength=50
jq -e '.["Invalid Vendor Codename - RTK 0x2775 0x20230923"].base == 40' "$XDG_STATE_HOME/dynamic-brightness/anchors.json" >/dev/null &&
  ok "switching on over dark content keeps 40 as the base" || fail "first anchor" "$(cat "$XDG_STATE_HOME/dynamic-brightness/anchors.json")"
# A white page comes up; wluma shows P - round(U * r) = 40 - 20 = 20.
wluma_shows DP-1 100 20
: >"$T/wluma.log"
run set DP-1 strength=25
# Still base 40: on white at strength 25 that is round(40 / 1.25) = 32.
[[ $(last_set) == "set brightness DP-1 32%" ]] && ok "strength 50 -> 25 on white: 20 -> 32, base kept at 40" ||
  fail "retune on white" "$(cat "$T/wluma.log")"
: >"$T/wluma.log"
run set DP-1 off
[[ $(last_set) == "set brightness DP-1 40%" ]] && ok "switching off hands back 40, not a dimmed value" ||
  fail "off restores base" "$(cat "$T/wluma.log")"
grep -q 'disable --now wluma.service' "$T/systemctl.log" && ok "last monitor off stops wluma" || fail "stop" "$(cat "$T/systemctl.log")"
teardown

setup
# Switched on while a white page is up, at 40 (wluma has no anchor yet).
wluma_shows DP-1 100 40
run set DP-1 on strength=50
[[ $(last_set) == "set brightness DP-1 27%" ]] && ok "switching on over white dims 40 to 27, base stays 40" ||
  fail "on over white" "$(cat "$T/wluma.log")"
: >"$T/wluma.log"
run set DP-1 off
[[ $(last_set) == "set brightness DP-1 40%" ]] && ok "an on/off pair over white is a no-op (was: 40 -> 60)" ||
  fail "on/off pair" "$(cat "$T/wluma.log")"
teardown

setup
wluma_shows DP-1 0 40
run set DP-1 on strength=50
# You turn the monitor up yourself while the white page is up: the panel
# now reads 30 where the anchor predicts 20.
wluma_shows DP-1 100 30
: >"$T/wluma.log"
run set DP-1 off
# wluma learned P = 30 + round(30 * 0.5) = 45 from that change.
[[ $(last_set) == "set brightness DP-1 45%" ]] && ok "a manual change since the anchor is honoured" ||
  fail "manual change" "$(cat "$T/wluma.log")"
teardown

setup
wluma_shows DP-1 0 95
run set DP-1 on strength=10
wluma_shows DP-1 0 95
# A base above 100 is possible: wluma's own anchor can exceed it when you
# set a high brightness over bright content.
jq '.["Invalid Vendor Codename - RTK 0x2775 0x20230923"].base = 130' "$XDG_STATE_HOME/dynamic-brightness/anchors.json" >"$T/a" &&
  mv "$T/a" "$XDG_STATE_HOME/dynamic-brightness/anchors.json"
: >"$T/wluma.log"
run set DP-1 off
[[ $(last_set) == "set brightness DP-1 100%" ]] && ok "restores are clamped to 100" || fail "clamp" "$(cat "$T/wluma.log")"
teardown

echo "settings that must not break wluma"
setup
mkdir -p "$(dirname "$SETTINGS")"
echo '{"version":1,"monitors":{"LG Electronics LG HDR 4K 0x00044DDB":{"enabled":true,"strength":250},
  "Invalid Vendor Codename - RTK J560J10 0x20240308":{"enabled":true,"strength":"lots"}}}' >"$SETTINGS"
cfg=$(run config)
grep -q 'reduction = 250' <<<"$cfg" && fail "strength 250 passed through" "$cfg" || ok "hand-edited strength clamped to 90"
[[ $(grep -c 'reduction = 90' <<<"$cfg") == 1 && $(grep -c 'reduction = 40' <<<"$cfg") == 1 ]] &&
  ok "non-numeric strength falls back to the default" || fail "fallback" "$cfg"
teardown

echo "identical monitors"
setup
cat >"$T/monitors.json" <<'EOF'
[
 {"name":"DP-1","description":"Dell U2720Q","serial":"","x":0,"y":0,"width":3840,"height":2160,"disabled":false,"dpmsStatus":true},
 {"name":"DP-2","description":"Dell U2720Q","serial":"","x":3840,"y":0,"width":3840,"height":2160,"disabled":false,"dpmsStatus":true}
]
EOF
run set DP-1 on
cfg=$(run config)
[[ $(grep -c 'predictor.manual\]' <<<"$cfg") == 1 ]] && ok "switching one on leaves its twin off" || fail "twins" "$cfg"
grep -q 'identifier' <<<"$cfg" && fail "empty serial used as identifier" "$cfg" || ok "no identifier without a serial"
teardown

setup
sed -i 's/"serial":"0x20230923"/"serial":"0x20240308"/' "$T/monitors.json"
run set HDMI-A-1 on
grep -q 'identifier' "$WCONF" && fail "shared serial used as identifier" "$(cat "$WCONF")" || ok "a serial two monitors share is not used"
teardown

echo "foreign wluma config"
setup
mkdir -p "$(dirname "$WCONF")"
echo '[als.iio]' >"$WCONF"
run set DP-2 on
ls "$WCONF".bak.* >/dev/null 2>&1 && ok "hand-written config backed up" || fail "backup"
teardown

echo "status"
setup
out=$(run status)
jq -e '.monitors | map(.label) == ["RTK J560J10","RTK 0x2775","LG Electronics LG HDR 4K"]' <<<"$out" >/dev/null &&
  ok "labels drop the vendor placeholder and serial" || fail "labels" "$out"
jq -e '.monitors | map(.position) == ["bottom-left","top-left","right"]' <<<"$out" >/dev/null &&
  ok "positions read off the layout" || fail "positions" "$(jq -c '.monitors | map(.position)' <<<"$out")"
jq -e '.wluma == {"installed":true,"running":false,"ready":false}' <<<"$out" >/dev/null && ok "reports wluma stopped" || fail "wluma state" "$out"
touch "$T/wluma-active"
out=$(run status)
jq -e '.wluma == {"installed":true,"running":true,"ready":false}' <<<"$out" >/dev/null &&
  ok "service up but IPC not yet answering = starting, not stopped" || fail "starting state" "$out"
sed -i '0,/"dpmsStatus":true/s//"dpmsStatus":false/' "$T/monitors.json"
out=$(run status)
jq -e '.monitors[0].active == false' <<<"$out" >/dev/null && ok "a monitor in DPMS sleep is not active" || fail "dpms" "$out"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
