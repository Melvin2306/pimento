import Foundation

/// `pimento help [command]` texts and shell completion scripts.
public enum CLIHelp {
    static let tenantOption = """
      -t, --tenant ID     Tenant GUID or domain. Default: $\(TenantResolver.environmentVariable),
                          then the tenant of az's current account.
    """

    public static func text(for topic: String?) -> String {
        switch topic {
        case "list": list
        case "activate": activate
        case "deactivate": deactivate
        case "renew": renew
        case "extend": extend
        case "status": status
        case "tenants": tenants
        case "presets": presets
        case "completions": completions
        case "version": "Usage: pimento version\n\nPrints the version."
        case "help": "Usage: pimento help [COMMAND]\n\nShows help for a command."
        default: main
        }
    }

    static let main = """
    \(AppInfo.name) \(AppInfo.version): \(AppInfo.tagline) from the command line.

    Usage: pimento <command> [options]

    Commands:
      list         List your eligible roles and whether they are active
      activate     Activate eligible roles (asks first; --dry-run sends nothing)
      deactivate   End active roles early
      renew        End and activate roles again, for a fresh duration
      extend       Ask an administrator to extend time-bound assignments
      status       Show your active roles, soonest-expiring first
      tenants      List the tenants your az login can reach
      presets      List, show, save or delete saved role presets
      completions  Print a completion script for zsh, bash or fish
      version      Print the version
      help         Show help for a command

    Common options:
    \(tenantOption)
          --json          Machine-readable output on stdout
      -h, --help          Show help

    Pimento uses your Azure CLI session (`az login`). The token stays in memory
    and is only sent to management.azure.com.

    Exit codes: 0 ok, 1 something failed, 2 usage error, 3 az missing or not signed in.
    Run `pimento help <command>` for details.
    """

    static let list = """
    Usage: pimento list [FILTER…] [--role NAME] [--active | --eligible] [--tenant ID] [--json]

    Lists your eligible Azure-resource roles and whether they are active.

    Arguments:
      FILTER              Resource name contains FILTER (case-insensitive). Several
                          filters are OR-ed. A filter starting with / is an ARM scope
                          and matches it and everything below it.

    Options:
          --role NAME     Role name, case-insensitive, whole name; * is a wildcard
                          (--role owner, --role '*contributor'). Repeatable.
          --active        Only roles that are active now
          --eligible      Only roles that are not active
    \(tenantOption)
          --json          JSON: {tenantId, user, roles: [... maxDuration, policy]}

    MAX is the longest activation each role's PIM policy allows (? when it could
    not be read). On a terminal the table is fitted to the window, with colour
    unless NO_COLOR is set. Piped, it prints plain aligned columns without the
    sign-in line.
    """

    static let activate = """
    Usage: pimento activate (FILTER… | --role NAME | --all | --preset NAME) -j TEXT [options]

    Activates the matching eligible roles that are not active yet, in parallel.

    Arguments:
      FILTER              Resource name contains FILTER (as in `pimento list`)

    Selection (at least one is required):
          --role NAME     Role name, whole name, * as wildcard. Repeatable.
          --all           Every eligible role (filters and --role still narrow it)
          --preset NAME   The roles of a saved preset (`pimento presets list`).
                          Its justification and duration apply unless -j / --hours
                          are given. Roles that are no longer eligible are reported
                          as missing; the rest is activated.

    Options:
      -j, --justification TEXT
                          Why you need the roles (required unless the preset has one)
          --hours N|max   Duration, 1-\(ActivationRequestBuilder.maxHours) (default \(ActivationRequestBuilder.defaultHours)), or max: the longest each
                          role's PIM policy allows. Each role gets at most its
                          policy maximum; the plan notes when a role was capped.
      -y, --yes           Don't ask. Required when stdin is not a terminal.
          --dry-run       Print the requests (PUT URL and body), send nothing
          --max-parallel N
                          Requests in flight at once, 1-\(ActivateOptions.maxParallelRange.upperBound) (default 8)
    \(tenantOption)
          --json          JSON: {dryRun, results: [...], summary: {...}}

    Pimento shows the plan, highlights Owner roles and asks before sending.
    Exit codes: 0 all activated or already active, 1 some failed (or you said no),
    2 usage error, 3 token missing or rejected.

    Examples:
      pimento activate prod --role Reader -j "INC-1234 look at logs" --hours 2
      pimento activate --all -j "on-call" --dry-run
      pimento activate --role owner contoso-dev -j "deploy" --yes --json
      pimento activate --preset On-call --hours max
    """

    static let deactivate = """
    Usage: pimento deactivate (FILTER… | --role NAME | --all | --preset NAME) [options]

    Ends the matching activations now (PIM's SelfDeactivate). Only active roles
    are considered. PIM refuses to end an activation in its first 5 minutes;
    such roles are reported with the time from which it is possible.

    Selection (at least one is required):
      FILTER              Resource name contains FILTER (as in `pimento list`)
          --role NAME     Role name, whole name, * as wildcard. Repeatable.
          --all           Every active role (filters and --role still narrow it)
          --preset NAME   The active roles of a saved preset

    Options:
      -j, --justification TEXT
                          Reason sent with the request (default: "\(ActivationRequestBuilder.defaultDeactivationJustification)")
      -y, --yes           Don't ask. Required when stdin is not a terminal.
          --dry-run       Print the requests, send nothing
          --max-parallel N
                          Requests in flight at once, 1-\(ActivateOptions.maxParallelRange.upperBound) (default 8)
    \(tenantOption)
          --json          JSON: {action, dryRun, results: [...], summary: {deactivated, …}}

    Exit codes: 0 ended (or not active), 1 something failed or was too soon
    (or you said no), 2 usage error, 3 token missing or rejected.

    Examples:
      pimento deactivate contoso-dev --role Contributor
      pimento deactivate --all --yes
    """

    static let renew = """
    Usage: pimento renew (FILTER… | --role NAME | --all | --preset NAME) -j TEXT [options]

    Gives active roles a fresh duration: each activation is ended (SelfDeactivate)
    and the role activated again (SelfActivate). PIM has no way to lengthen your
    own activation; see `pimento help extend`.

    In between, the role is NOT active: PIM accepts the new activation only once
    it has removed the old one, typically after 1-3 minutes. Pimento keeps
    trying for 5 minutes. If activating again fails, the role stays off:
    activate it again. Roles whose policy requires approval are not renewed.
    Roles activated less than 5 minutes ago cannot be ended yet.

    Selection: as for deactivate (FILTER…, --role, --all, --preset).

    Options:
      -j, --justification TEXT
                          Why you need the roles (required unless the preset has one)
          --hours N|max   New duration, 1-\(ActivationRequestBuilder.maxHours) (default \(ActivationRequestBuilder.defaultHours)) or max; capped at
                          each role's policy maximum
      -y, --yes           Don't ask. Required when stdin is not a terminal.
          --dry-run       Print both requests per role, send nothing
          --max-parallel N
                          Roles renewed at once (at most 4)
    \(tenantOption)
          --json          JSON: {action, dryRun, results: [...], summary: {renewed, …}}

    Examples:
      pimento renew contoso-dev --role Contributor -j "INC-1234 still on it" --hours 2
      pimento renew --preset On-call --yes
    """

    static let extend = """
    Usage: pimento extend (FILTER… | --role NAME | --all) -j TEXT [--days N] [options]

    Asks for admin-assigned, time-bound active assignments to be extended
    (PIM's SelfExtend). This is a request: an administrator of the resource must
    approve it (status PendingAdminDecision) and sets the final dates; until then
    nothing changes. Cancel a request in the Azure portal (PIM, My requests).

    PIM activations are left out: PIM does not let you extend your own
    activation (it files the request for an administrator and keeps the end
    time). Use `pimento renew` for those.

    Options:
      -j, --justification TEXT
                          Why you need the extension (required)
          --days N        Ask for the end to move N days, \(ExtendOptionsRange.days.lowerBound)-\(ExtendOptionsRange.days.upperBound) (default \(ExtendOptionsRange.defaultDays))
      -y, --yes           Don't ask. Required when stdin is not a terminal.
          --dry-run       Print the requests, send nothing
    \(tenantOption)
          --json          JSON: {action, dryRun, results: [...], summary: {...}}
    """

    static let status = """
    Usage: pimento status [--tenant ID] [--json]

    Shows the roles that are active now, soonest-expiring first, with the time left.

    Options:
    \(tenantOption)
          --json          JSON: {tenantId, user, roles: [... secondsLeft]}
    """

    static let tenants = """
    Usage: pimento tenants [--tenant ID] [--json]

    Lists the tenants your az login can reach: ARM's GET /tenants plus az's
    account cache. Read-only.

    Options:
      -t, --tenant ID     Ask ARM with a token for this tenant (default: az's current one)
          --json          JSON: {tenants: [{id, displayName, defaultDomain, category}]}
    """

    static let presets = """
    Usage: pimento presets [list] [--tenant ID] [--json]
           pimento presets show NAME [--tenant ID] [--json]
           pimento presets save NAME (FILTER… | --role NAME…) [--exact] [-j TEXT] [--hours N|max] [--force]
           pimento presets delete NAME [--tenant ID]

    A preset is a named set of roles with an optional justification and duration,
    for `pimento activate --preset NAME`. The app and the CLI share the file
    ~/Library/Application Support/Pimento/presets.json ($\(PresetStore.environmentVariable) overrides it).
    Presets belong to a tenant; with one preset of a name, activate uses its tenant.

    save stores the filters as a rule that is resolved at activation time, so new
    eligibilities that match are included. --exact stores the roles that match now
    instead. save reads your roles (read-only) to find the tenant and show matches.

    Options:
          --role NAME     Role name, whole name, * as wildcard. Repeatable.
          --exact         Store the matching roles, not the filters
      -j, --justification TEXT
                          Default justification for the preset
          --hours N|max   Default duration
      -f, --force         Replace a preset with the same name
    \(tenantOption)
          --json          JSON output

    Examples:
      pimento presets save On-call prod --role Owner -j "on-call" --hours max
      pimento presets save Deploy contoso-dev --role Contributor --exact
      pimento activate --preset On-call --yes
    """

    static let completions = """
    Usage: pimento completions zsh|bash|fish

    Prints a completion script. For example:

      zsh:   pimento completions zsh > "${fpath[1]}/_pimento"   (then restart the shell)
      bash:  pimento completions bash > ~/.local/share/bash-completion/completions/pimento
      fish:  pimento completions fish > ~/.config/fish/completions/pimento.fish
    """

    // MARK: Completions

    public static func completionScript(for shell: CompletionShell) -> String {
        switch shell {
        case .zsh: zsh
        case .bash: bash
        case .fish: fish
        }
    }

    static let zsh = #"""
    #compdef pimento
    # zsh completion for pimento. Install: pimento completions zsh > "${fpath[1]}/_pimento"

    _pimento() {
      local -a commands common selection
      commands=(
        'list:List your eligible roles and whether they are active'
        'activate:Activate eligible roles'
        'deactivate:End active roles early'
        'renew:End and activate roles again'
        'extend:Ask an administrator to extend time-bound assignments'
        'status:Show your active roles, soonest-expiring first'
        'tenants:List the tenants your az login can reach'
        'presets:List, show, save or delete role presets'
        'completions:Print a completion script'
        'version:Print the version'
        'help:Show help for a command'
      )
      common=(
        '(-t --tenant)'{-t,--tenant}'[Tenant GUID or domain]:tenant: '
        '--json[Machine-readable output]'
        '(- *)'{-h,--help}'[Show help]'
      )
      _arguments -C '1: :->command' '*:: :->args' && return
      case $state in
        command) _describe -t commands 'pimento command' commands ;;
        args)
          case $words[1] in
            list)
              _arguments -s $common \
                '*--role[Role name, * as wildcard]:role: ' \
                '(--eligible)--active[Only active roles]' \
                '(--active)--eligible[Only roles that are not active]' \
                '*:resource filter: ' ;;
            activate)
              _arguments -s $common \
                '*--role[Role name, * as wildcard]:role: ' \
                '--all[Every eligible role]' \
                '(-j --justification)'{-j,--justification}'[Justification]:justification: ' \
                '--hours[Duration in hours, or max]:hours:(max 1 2 4 8 12 24)' \
                '--preset[Saved preset]:preset: ' \
                '(-y --yes)'{-y,--yes}'[Do not ask for confirmation]' \
                '--dry-run[Print the requests, send nothing]' \
                '--max-parallel[Requests in flight at once]:count: ' \
                '*:resource filter: ' ;;
            deactivate|renew)
              _arguments -s $common \
                '*--role[Role name, * as wildcard]:role: ' \
                '--all[Every active role]' \
                '(-j --justification)'{-j,--justification}'[Justification]:justification: ' \
                '--hours[New duration in hours, or max (renew)]:hours:(max 1 2 4 8 12 24)' \
                '--preset[Saved preset]:preset: ' \
                '(-y --yes)'{-y,--yes}'[Do not ask for confirmation]' \
                '--dry-run[Print the requests, send nothing]' \
                '--max-parallel[Requests in flight at once]:count: ' \
                '*:resource filter: ' ;;
            extend)
              _arguments -s $common \
                '*--role[Role name, * as wildcard]:role: ' \
                '--all[Every time-bound assignment]' \
                '(-j --justification)'{-j,--justification}'[Justification]:justification: ' \
                '--days[Days to extend by]:days:(7 30 90 180 365)' \
                '(-y --yes)'{-y,--yes}'[Do not ask for confirmation]' \
                '--dry-run[Print the requests, send nothing]' \
                '*:resource filter: ' ;;
            status|tenants) _arguments -s $common ;;
            presets)
              _arguments -s $common \
                '1:presets command:(list show save delete)' \
                '*--role[Role name, * as wildcard]:role: ' \
                '--exact[Store the matching roles, not the filters]' \
                '(-j --justification)'{-j,--justification}'[Default justification]:justification: ' \
                '--hours[Default duration]:hours:(max 1 2 4 8 12 24)' \
                '(-f --force)'{-f,--force}'[Replace a preset with the same name]' \
                '*:name or filter: ' ;;
            completions) _arguments '1:shell:(zsh bash fish)' ;;
            help) _arguments '1:command:(list activate deactivate renew extend status tenants presets completions version)' ;;
          esac ;;
      esac
    }

    if [ "$funcstack[1]" = "_pimento" ]; then
      _pimento "$@"
    else
      compdef _pimento pimento
    fi
    """#

    static let bash = #"""
    # bash completion for pimento. Install: pimento completions bash > ~/.local/share/bash-completion/completions/pimento
    _pimento() {
      local cur prev cmd opts
      cur="${COMP_WORDS[COMP_CWORD]}"
      prev="${COMP_WORDS[COMP_CWORD-1]}"
      cmd="${COMP_WORDS[1]}"
      if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=($(compgen -W "list activate deactivate renew extend status tenants presets completions version help" -- "$cur"))
        return
      fi
      case "$prev" in
        -t|--tenant|-j|--justification|--role|--max-parallel|--preset|--days) return ;;
        --hours) COMPREPLY=($(compgen -W "max 1 2 4 8 12 24" -- "$cur")); return ;;
      esac
      case "$cmd" in
        list) opts="--tenant --json --role --active --eligible --help" ;;
        activate) opts="--tenant --json --role --all --preset --justification --hours --yes --dry-run --max-parallel --help" ;;
        deactivate) opts="--tenant --json --role --all --preset --justification --yes --dry-run --max-parallel --help" ;;
        renew) opts="--tenant --json --role --all --preset --justification --hours --yes --dry-run --max-parallel --help" ;;
        extend) opts="--tenant --json --role --all --justification --days --yes --dry-run --help" ;;
        status|tenants) opts="--tenant --json --help" ;;
        presets)
          if [[ $COMP_CWORD -eq 2 ]]; then opts="list show save delete"
          else opts="--tenant --json --role --exact --justification --hours --force --help"; fi ;;
        completions) opts="zsh bash fish" ;;
        help) opts="list activate deactivate renew extend status tenants presets completions version" ;;
        *) opts="" ;;
      esac
      COMPREPLY=($(compgen -W "$opts" -- "$cur"))
    }
    complete -F _pimento pimento
    """#

    static let fish = #"""
    # fish completion for pimento. Install: pimento completions fish > ~/.config/fish/completions/pimento.fish
    complete -c pimento -f
    complete -c pimento -n __fish_use_subcommand -a list -d 'List your eligible roles'
    complete -c pimento -n __fish_use_subcommand -a activate -d 'Activate eligible roles'
    complete -c pimento -n __fish_use_subcommand -a deactivate -d 'End active roles early'
    complete -c pimento -n __fish_use_subcommand -a renew -d 'End and activate roles again'
    complete -c pimento -n __fish_use_subcommand -a extend -d 'Ask an administrator to extend time-bound assignments'
    complete -c pimento -n __fish_use_subcommand -a status -d 'Show your active roles'
    complete -c pimento -n __fish_use_subcommand -a tenants -d 'List the tenants your az login can reach'
    complete -c pimento -n __fish_use_subcommand -a presets -d 'List, show, save or delete role presets'
    complete -c pimento -n __fish_use_subcommand -a completions -d 'Print a completion script'
    complete -c pimento -n __fish_use_subcommand -a version -d 'Print the version'
    complete -c pimento -n __fish_use_subcommand -a help -d 'Show help for a command'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew extend status tenants presets' -s t -l tenant -r -d 'Tenant GUID or domain'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew extend status tenants presets' -l json -d 'Machine-readable output'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew extend status tenants presets' -s h -l help -d 'Show help'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew extend presets' -l role -r -d 'Role name, * as wildcard'
    complete -c pimento -n '__fish_seen_subcommand_from list' -l active -d 'Only active roles'
    complete -c pimento -n '__fish_seen_subcommand_from list' -l eligible -d 'Only roles that are not active'
    complete -c pimento -n '__fish_seen_subcommand_from activate' -l all -d 'Every eligible role'
    complete -c pimento -n '__fish_seen_subcommand_from deactivate renew extend' -l all -d 'Every active role'
    complete -c pimento -n '__fish_seen_subcommand_from extend' -l days -x -a '7 30 90 180 365' -d 'Days to extend by'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew extend presets' -s j -l justification -r -d 'Justification'
    complete -c pimento -n '__fish_seen_subcommand_from activate renew presets' -l hours -x -a 'max 1 2 4 8 12 24' -d 'Duration in hours, or max'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew' -l preset -r -d 'Saved preset'
    complete -c pimento -n '__fish_seen_subcommand_from presets; and not __fish_seen_subcommand_from list show save delete' -a 'list show save delete'
    complete -c pimento -n '__fish_seen_subcommand_from presets' -l exact -d 'Store the matching roles, not the filters'
    complete -c pimento -n '__fish_seen_subcommand_from presets' -s f -l force -d 'Replace a preset with the same name'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew extend' -s y -l yes -d 'Do not ask for confirmation'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew extend' -l dry-run -d 'Print the requests, send nothing'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew' -l max-parallel -x -d 'Requests in flight at once'
    complete -c pimento -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish'
    complete -c pimento -n '__fish_seen_subcommand_from help' -a 'list activate deactivate renew extend status tenants presets completions version'
    """#
}
