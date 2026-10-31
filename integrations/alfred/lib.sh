# Shared by scriptfilter.sh and action.sh (sourced, POSIX sh).
#
# Alfred passes the workflow configuration as environment variables:
#   pimento_path   the pimento binary (empty: look it up, see pim_find)
#   tenant         --tenant for list/activate/deactivate (empty: the CLI's default)
#   demo_mode      1: run everything with --demo (synthetic data, offline)
#   default_hours  duration for ↩ (1-24 or max; default 8)
# and alfred_workflow_cache, a folder for the workflow's cache.

pim_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Alfred always sets alfred_workflow_cache; the fallback is never a shared /tmp folder.
pim_cache=${alfred_workflow_cache:-$HOME/Library/Caches/pimento-alfred}
# The role list and results are only for you.
umask 077
pim_app_helper=/Applications/Pimento.app/Contents/Helpers/pimento
# How long the role list is reused while you type (seconds). Any action clears it.
pim_ttl=60

pim_demo() {
  case ${demo_mode:-} in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# True when FILE (a regular executable file) can be run: the real file
# (symbolic links followed) and its folder belong to root or you, nobody else
# may write them (unless root's and sticky, like /tmp), and their group may
# only for wheel or admin. The CLI's rule for az (PathTrust.isTrusted).
pim_trusted() {
  [ -f "$1" ] && [ -x "$1" ] || return 1
  real=$(realpath "$1" 2>/dev/null) || return 1
  me=$(id -u)
  for p in "$real" "$(dirname -- "$real")"; do
    info=$(stat -f '%u %g %Lp' "$p" 2>/dev/null) || return 1
    IFS=' ' read -r uid gid perm <<EOF
$info
EOF
    perm=$((0$perm))
    [ "$uid" = 0 ] || [ "$uid" = "$me" ] || return 1
    if [ $((perm & 2)) -ne 0 ] && ! { [ "$uid" = 0 ] && [ $((perm & 512)) -ne 0 ]; }; then return 1; fi
    if [ $((perm & 16)) -ne 0 ]; then
      case $gid in 0 | 80) ;; *) return 1 ;; esac
    fi
  done
  return 0
}

# Prints the pimento to run: pimento_path when set; else ~/.local/bin/pimento,
# then PATH plus the Homebrew folders (Alfred's PATH is short), then the copy
# inside Pimento.app, each only when pim_trusted. Fails when there is none.
pim_find() {
  if [ -n "${pimento_path:-}" ]; then
    case $pimento_path in
      # "~/…": the home folder (Alfred does not expand it). Drop the two characters.
      \~/*) printf '%s/%s\n' "$HOME" "${pimento_path#??}" ;;
      *) printf '%s\n' "$pimento_path" ;;
    esac
    return 0
  fi
  if pim_trusted "$HOME/.local/bin/pimento"; then
    printf '%s\n' "$HOME/.local/bin/pimento"
    return 0
  fi
  set -f
  old_ifs=$IFS
  IFS=:
  for dir in $PATH /opt/homebrew/bin /usr/local/bin; do
    # Absolute folders only: a relative PATH entry would depend on the working directory.
    case $dir in /*) ;; *) continue ;; esac
    if pim_trusted "$dir/pimento"; then
      IFS=$old_ifs
      set +f
      printf '%s\n' "$dir/pimento"
      return 0
    fi
  done
  IFS=$old_ifs
  set +f
  if pim_trusted "$pim_app_helper"; then
    printf '%s\n' "$pim_app_helper"
    return 0
  fi
  return 1
}

# One cache key per mode and tenant, so switching either never shows stale roles.
pim_key() {
  if pim_demo; then mode=demo; else mode=live; fi
  printf '%s-%s' "$mode" "$(printf '%s' "${tenant:-default}" | tr -c 'A-Za-z0-9.-' '_')"
}

# True when FILE exists, is not empty and is younger than pim_ttl seconds.
pim_fresh() {
  [ -s "$1" ] || return 1
  age=$(($(date +%s) - $(stat -f %m "$1")))
  [ "$age" -ge 0 ] && [ "$age" -lt "$pim_ttl" ]
}

pim_clear_cache() {
  rm -f "$pim_cache"/roles-*.json "$pim_cache"/presets-*.json
}

# pim_run BINARY OUT ERR [--no-tenant] ARG...
# Runs BINARY with --demo / --tenant from the configuration and ARG..., as an
# argument list (no shell string). stdout goes to OUT (only on success, atomically:
# a cancelled run never leaves half a file), stderr to ERR. Returns its exit code.
pim_run() {
  bin=$1 out=$2 err=$3
  shift 3
  with_tenant=1
  if [ "${1:-}" = --no-tenant ]; then
    with_tenant=0
    shift
  fi
  if [ -n "${tenant:-}" ] && [ "$with_tenant" = 1 ]; then set -- "--tenant=$tenant" "$@"; fi
  if pim_demo; then set -- --demo "$@"; fi
  mkdir -p "$pim_cache"
  NO_COLOR=1 "$bin" "$@" >"$out.$$" 2>"$err" </dev/null
  status=$?
  if [ "$status" -eq 0 ]; then mv -f "$out.$$" "$out"; else
    # activate/deactivate print their result document also on exit 1.
    if [ -s "$out.$$" ]; then mv -f "$out.$$" "$out"; else rm -f "$out.$$"; fi
  fi
  return "$status"
}

# pim_js MODE ARG...: alfred.js turns pimento's JSON into Alfred's.
pim_js() {
  osascript -l JavaScript "$pim_here/alfred.js" "$@"
}
