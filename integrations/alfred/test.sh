#!/bin/sh
# Tests the workflow's scripts against `pimento --demo` (offline, synthetic
# data), without Alfred: runs scriptfilter.sh and action.sh the way Alfred
# does (query as $1, the item's variables in the environment) and checks
# their JSON with python3.
#
#   integrations/alfred/test.sh [PIMENTO]    default: .build/debug/pimento

set -u
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$here/../.." && pwd)
bin=${1:-$root/.build/debug/pimento}
[ -x "$bin" ] || {
  echo "no pimento at $bin: run swift build, or pass its path" >&2
  exit 2
}

cache=$(mktemp -d "${TMPDIR:-/tmp}/pimento-alfred-test.XXXXXX")
trap 'rm -rf "$cache"' EXIT INT TERM
export pimento_path="$bin" demo_mode=1 alfred_workflow_cache="$cache" default_hours=2
unset tenant pim_action pim_id pim_preset pim_preset_id pim_preset_tenant pim_justification pim_hours pim_label 2>/dev/null || :

failures=0
pass() { printf 'ok    %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}

# check NAME PYTHON-EXPRESSION JSON: the expression sees the parsed JSON as d.
check() {
  if printf '%s' "$3" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($2) else 1)" 2>/dev/null; then
    pass "$1"
  else
    fail "$1"
    printf '%s\n' "$3" | head -c 2000
    echo
  fi
}

# Script Filter
out=$("$here/scriptfilter.sh" "")
check "lists presets first, then active, then eligible roles" \
  'd["skipknowledge"] and [i["title"] for i in d["items"][:3]] == ["Preset: Data team", "Preset: On-call", "Preset: Release day"] and d["items"][3]["subtitle"].startswith("Active")' "$out"
check "every role has an autocomplete with its @token" \
  'all("@" in i["autocomplete"] for i in d["items"] if i.get("uid","").startswith("role:"))' "$out"
check "a role needing a ticket is not actionable" \
  'all(not i["valid"] for i in d["items"] if "needs a ticket" in i.get("subtitle",""))' "$out"
check "demo mode is labelled" 'd["items"][-1]["title"] == "Demo mode"' "$out"
if [ -s "$cache/roles-demo-default.json" ]; then pass "role list cached"; else fail "role list cached"; fi

out=$("$here/scriptfilter.sh" "staging contributor")
check "words narrow the list (all must match)" \
  '[i["title"] for i in d["items"] if i.get("uid","").startswith("role:")] == ["Contributor · Contoso Staging"]' "$out"

token=$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print([i for i in d["items"] if i.get("uid","").startswith("role:")][0]["autocomplete"].split("@")[1].split()[0])')
out=$("$here/scriptfilter.sh" "Contributor · Contoso Staging @$token > Release 2026.11")
check "@token picks one role; > text is the justification" \
  'len(d["items"]) == 2 and d["items"][0]["valid"] and d["items"][0]["variables"]["pim_justification"] == "Release 2026.11" and d["items"][0]["variables"]["pim_hours"] == "2" and d["items"][0]["mods"]["cmd"]["variables"]["pim_hours"] == "max"' "$out"
role_id=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["variables"]["pim_id"])')

out=$("$here/scriptfilter.sh" "Contributor · Contoso Staging @$token > ")
check "after > without text: not yet actionable" 'not d["items"][0]["valid"] and "Type the justification" in d["items"][0]["subtitle"]' "$out"

out=$("$here/scriptfilter.sh" "On-call > ")
check "an exact preset name shows only that preset" \
  'len(d["items"]) == 2 and d["items"][0]["title"] == "Preset: On-call" and d["items"][0]["valid"]' "$out"
out=$("$here/scriptfilter.sh" "On-call > -covering for Sam")
check "a typed justification overrides the preset's" \
  'd["items"][0]["variables"]["pim_justification"] == "-covering for Sam" and d["items"][0]["variables"]["pim_preset_tenant"]' "$out"

out=$("$here/scriptfilter.sh" "zzz-nothing")
check "no match says so" 'd["items"][0]["title"] == "No matching role or preset"' "$out"

out=$("$here/scriptfilter.sh" "owner staging > Rotate keys")
check "an Owner role says so before ↩" \
  '[i["subtitle"] for i in d["items"] if i.get("uid","").startswith("role:")][0].startswith("Owner: full control")' "$out"

# Names containing > or @ must not move the split or the handle (alfred.js on fixtures).
cat >"$cache/fx-roles.json" <<'EOF'
{"roles":[
{"id":"/s/x/i/11111111-0000-0000-0000-000000000000","eligibilityScheduleId":"/s/x/e/bbbbbbbb-0000-0000-0000-000000000000","roleName":"Contributor","scope":"/s/x","scopeName":"Prod","scopeType":"subscription","isOwner":false,"isActive":false},
{"id":"/s/y/i/22222222-0000-0000-0000-000000000000","eligibilityScheduleId":"/s/y/e/aaaaaaaa-0000-0000-0000-000000000000","roleName":"Contributor","scope":"/s/y","scopeName":"Prod > EU @beef","scopeType":"subscription","isOwner":false,"isActive":false}
]}
EOF
cat >"$cache/fx-presets.json" <<'EOF'
{"presets":[
{"id":"p1","name":"Prod","roles":[{"scope":"/s/x","roleDefinitionId":"r"}]},
{"id":"p2","name":"Prod > Admin","roles":[{"scope":"/s/y","roleDefinitionId":"r"}]},
{"id":"p3","name":"Shared","roles":[{"scope":"/s/x","roleDefinitionId":"r"}],"justification":"j"},
{"id":"p4","name":"shared","tenantId":"00000000-0000-0000-0000-00000000000a","roles":[{"scope":"/s/y","roleDefinitionId":"r"}],"justification":"j"}
]}
EOF
fx() { osascript -l JavaScript "$here/alfred.js" items "$cache/fx-roles.json" "$cache/fx-presets.json" "$1" 8; }
ac=$(fx "eu" | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin)["items"] if i.get("uid","").startswith("role:")][0]["autocomplete"])')
out=$(fx "${ac}Release")
check "a scope name with > and @: the picked role stays the only one" \
  '[(i["variables"]["pim_id"][-36:], i["variables"]["pim_justification"]) for i in d["items"] if i.get("valid")] == [("22222222-0000-0000-0000-000000000000", "Release")]' "$out"
ac=$(fx "admin" | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin)["items"] if i["title"].startswith("Preset")][0]["autocomplete"])')
out=$(fx "${ac}Release")
check "a preset name with >: that preset, not the shorter one" \
  '[i["variables"]["pim_preset"] for i in d["items"] if i.get("valid")] == ["Prod > Admin"]' "$out"
out=$(fx "shared")
check "presets that share a name are each activated by their own id" \
  '{i["variables"]["pim_preset_tenant"]: (i["valid"], i["variables"]["pim_preset_id"]) for i in d["items"] if i["title"].startswith("Preset")} == {"": (True, "p3"), "00000000-0000-0000-0000-00000000000a": (True, "p4")}' "$out"

# Run Script
out=$(pim_action=activate pim_id="$role_id" pim_justification="-Release; rm -rf ~" pim_hours=2 pim_label="x" "$here/action.sh")
check "activate by id, justification passed verbatim" \
  'd["alfredworkflow"]["variables"]["pim_title"] == "Pimento: activated" and d["alfredworkflow"]["arg"].startswith("Contributor · Contoso Staging until")' "$out"
if [ -e "$cache/roles-demo-default.json" ]; then fail "an action clears the cache"; else pass "an action clears the cache"; fi

owner=$("$here/scriptfilter.sh" "owner production" | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin)["items"] if i.get("uid","").startswith("role:")][0]["variables"]["pim_id"])')
out=$(pim_action=activate pim_id="$owner" pim_justification="Rotate" pim_hours=max "$here/action.sh")
check "approval: awaiting approval with the request" \
  'd["alfredworkflow"]["variables"]["pim_title"] == "Pimento: awaiting approval" and "request" in d["alfredworkflow"]["arg"]' "$out"

ticket=$("$here/scriptfilter.sh" "" | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin)["items"] if "needs a ticket" in i.get("subtitle","")][0]["variables"]["pim_id"])')
out=$(pim_action=activate pim_id="$ticket" pim_justification="x" "$here/action.sh")
check "a CLI error (exit 2) becomes a readable notification" \
  'd["alfredworkflow"]["variables"]["pim_title"] == "Pimento: Not possible as asked" and "needs a ticket" in d["alfredworkflow"]["arg"]' "$out"

oncall=$("$here/scriptfilter.sh" "On-call > " | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["variables"]["pim_preset_id"])')
out=$(pim_action=preset pim_preset_id="$oncall" pim_preset_tenant="" pim_justification="" pim_hours="" pim_label="preset On-call" "$here/action.sh")
check "preset: summary of what happened" \
  'd["alfredworkflow"]["arg"] == "2 activated, 1 already done"' "$out"
out=$(pim_action=preset pim_preset_id="00000000-0000-0000-0000-00000000dead" "$here/action.sh")
check "unknown preset: the CLI's message" \
  '"No preset has the id" in d["alfredworkflow"]["arg"]' "$out"

active=$("$here/scriptfilter.sh" "development" | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin)["items"] if i.get("uid","").startswith("role:")][0]["mods"]["alt"]["variables"]["pim_id"])')
out=$(pim_action=deactivate pim_id="$active" "$here/action.sh")
check "deactivate by id (⌥↩ on an active role)" \
  'd["alfredworkflow"]["variables"]["pim_title"] == "Pimento: deactivated" and d["alfredworkflow"]["arg"] == "Contributor · Contoso Development"' "$out"

# Errors
out=$(pimento_path=/nonexistent/pimento "$here/scriptfilter.sh" "")
check "a missing binary is reported" '"could not be run" in d["items"][0]["title"] and "pimento_path" in d["items"][0]["subtitle"]' "$out"
# Only where nothing is installed: it must never run some other pimento.
if [ -x /Applications/Pimento.app/Contents/Helpers/pimento ] || [ -x /opt/homebrew/bin/pimento ] || [ -x /usr/local/bin/pimento ]; then
  pass "lookup without pimento_path (skipped: an installed pimento would be found)"
else
  out=$(pimento_path='' PATH=/usr/bin:/bin HOME="$cache" "$here/scriptfilter.sh" "")
  check "nothing installed: pimento not found" 'd["items"][0]["title"] == "Pimento: pimento not found"' "$out"
fi
# A relative PATH entry is never searched: it would depend on the working directory.
mkdir -p "$cache/cwd/relbin" "$cache/home"
printf '#!/bin/sh\n: >"%s/ran"\n' "$cache" >"$cache/cwd/relbin/pimento"
chmod 755 "$cache/cwd/relbin/pimento"
(cd "$cache/cwd" && pimento_path='' PATH=relbin:/usr/bin:/bin HOME="$cache/home" "$here/scriptfilter.sh" "" >/dev/null)
if [ -e "$cache/ran" ]; then fail "a relative PATH entry is not searched"; else pass "a relative PATH entry is not searched"; fi
# A pimento someone else could have placed or changed is skipped: one in a folder
# others can write, or one its group can write. One only you can change is used.
for d in shared grp own; do
  mkdir -p "$cache/$d"
  printf '#!/bin/sh\n: >"%s/ran-%s"\nexit 3\n' "$cache" "$d" >"$cache/$d/pimento"
  chmod 755 "$cache/$d" "$cache/$d/pimento"
done
chmod 777 "$cache/shared"
chgrp "$(id -g)" "$cache/grp/pimento"
chmod 775 "$cache/grp/pimento"
pimento_path='' PATH="$cache/shared:$cache/grp:$cache/own:/usr/bin:/bin" HOME="$cache/home" alfred_workflow_cache="$cache/fresh" "$here/scriptfilter.sh" "" >/dev/null
if [ -e "$cache/ran-shared" ] || [ -e "$cache/ran-grp" ]; then fail "a pimento others can change is not run"; else pass "a pimento others can change is not run"; fi
if [ -e "$cache/ran-own" ]; then pass "a pimento only you can change is run"; else fail "a pimento only you can change is run"; fi
out=$(pim_action=bogus "$here/action.sh")
check "an unknown action does nothing" '"Unknown action" in d["alfredworkflow"]["arg"]' "$out"

# The workflow definition
if plutil -lint "$here/info.plist" >/dev/null; then pass "info.plist is a valid plist"; else fail "info.plist is a valid plist"; fi

echo
if [ "$failures" -eq 0 ]; then
  echo "All Alfred workflow tests passed."
else
  echo "$failures Alfred workflow test(s) failed."
  exit 1
fi
