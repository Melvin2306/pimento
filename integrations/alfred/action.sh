#!/bin/sh
# Alfred Run Script: does what the selected item says, from the item's variables:
#   pim_action   activate | preset | deactivate
#   pim_id       the role's id from `pimento list --json` (activate, deactivate)
#   pim_preset_id, pim_preset_tenant   the preset's id and tenant (preset)
#   pim_justification, pim_hours    for activate and preset (empty: the preset's)
#   pim_label    what to call it in the notification
# Prints Alfred's {"alfredworkflow": …} JSON: the notification text as arg, its
# title in the variable pim_title.

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname -- "$0")/lib.sh"

if ! bin=$(pim_find); then
  pim_js notfound result
  exit 0
fi

tenant_mode=
case ${pim_action:-} in
  activate)
    set -- activate "--id=${pim_id:?}" "--justification=${pim_justification:?}" "--hours=${pim_hours:-8}"
    ;;
  preset)
    # By id: a name can fit presets of two tenants.
    set -- activate "--preset-id=${pim_preset_id:?}"
    if [ -n "${pim_preset_tenant:-}" ]; then
      # A preset belongs to its tenant: that one, not the configured default.
      set -- "$@" "--tenant=$pim_preset_tenant"
      tenant_mode=--no-tenant
    fi
    if [ -n "${pim_justification:-}" ]; then set -- "$@" "--justification=$pim_justification"; fi
    if [ -n "${pim_hours:-}" ]; then set -- "$@" "--hours=$pim_hours"; fi
    ;;
  deactivate)
    set -- deactivate "--id=${pim_id:?}"
    ;;
  *)
    pim_js usage result "${pim_action:-}"
    exit 0
    ;;
esac
# ↩ in Alfred is the confirmation the CLI asks for on a terminal.
set -- "$@" --yes --json

mkdir -p "$pim_cache"
out=$pim_cache/result-$$.json
err=$pim_cache/result-$$.txt
if [ -n "$tenant_mode" ]; then
  pim_run "$bin" "$out" "$err" "$tenant_mode" "$@"
else
  pim_run "$bin" "$out" "$err" "$@"
fi
code=$?
# The roles changed: the next `pim` reads them again.
pim_clear_cache
pim_js result "$code" "$out" "$err" "${pim_label:-}"
rm -f "$out" "$err"
