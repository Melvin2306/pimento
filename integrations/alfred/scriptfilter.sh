#!/bin/sh
# Alfred Script Filter for the `pim` keyword: presets and roles from
# `pimento list --json` and `pimento presets list --json`, as Alfred JSON.
#
#   pim [WORDS]                 presets and roles whose names contain every word
#   pim [WORDS] > JUSTIFICATION ↩ activates the selected role or preset with it
#
# Query in $1 (Alfred: "with input as argv").

query=${1-}
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname -- "$0")/lib.sh"

if ! bin=$(pim_find); then
  pim_js notfound
  exit 0
fi

key=$(pim_key)
roles=$pim_cache/roles-$key.json
presets=$pim_cache/presets-$key.json
err=$pim_cache/stderr-$key.txt

if ! pim_fresh "$roles"; then
  pim_run "$bin" "$roles" "$err" list --json
  code=$?
  if [ "$code" -ne 0 ]; then
    rm -f "$roles"
    pim_js error "$code" "$err" "$bin"
    exit 0
  fi
fi
if ! pim_fresh "$presets"; then
  # Presets are local and per tenant: all of them, offline. None is fine.
  pim_run "$bin" "$presets" "$err" --no-tenant presets list --json || : >"$presets"
fi

pim_js items "$roles" "$presets" "$query" "${default_hours:-8}" "$(pim_demo && echo demo)"
