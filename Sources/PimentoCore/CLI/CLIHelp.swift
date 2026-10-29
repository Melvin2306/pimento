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
        case "status": status
        case "tenants": tenants
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
      status       Show your active roles, soonest-expiring first
      tenants      List the tenants your az login can reach
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
          --json          JSON: {tenantId, user, roles: [...]}

    On a terminal the table is fitted to the window, with colour unless NO_COLOR is
    set. Piped, it prints plain aligned columns without the sign-in line.
    """

    static let activate = """
    Usage: pimento activate (FILTER… | --role NAME | --all) -j TEXT [options]

    Activates the matching eligible roles that are not active yet, in parallel.

    Arguments:
      FILTER              Resource name contains FILTER (as in `pimento list`)

    Selection (at least one is required):
          --role NAME     Role name, whole name, * as wildcard. Repeatable.
          --all           Every eligible role (filters and --role still narrow it)

    Options:
      -j, --justification TEXT
                          Why you need the roles (required)
          --hours N       Duration, 1-\(ActivationRequestBuilder.maxHours) (default \(ActivationRequestBuilder.defaultHours)). The role's PIM policy may allow less.
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
        'status:Show your active roles, soonest-expiring first'
        'tenants:List the tenants your az login can reach'
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
                '--hours[Duration in hours]:hours:(1 2 4 8 12 24)' \
                '(-y --yes)'{-y,--yes}'[Do not ask for confirmation]' \
                '--dry-run[Print the requests, send nothing]' \
                '--max-parallel[Requests in flight at once]:count: ' \
                '*:resource filter: ' ;;
            status|tenants) _arguments -s $common ;;
            completions) _arguments '1:shell:(zsh bash fish)' ;;
            help) _arguments '1:command:(list activate status tenants completions version)' ;;
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
        COMPREPLY=($(compgen -W "list activate status tenants completions version help" -- "$cur"))
        return
      fi
      case "$prev" in
        -t|--tenant|-j|--justification|--role|--max-parallel) return ;;
        --hours) COMPREPLY=($(compgen -W "1 2 4 8 12 24" -- "$cur")); return ;;
      esac
      case "$cmd" in
        list) opts="--tenant --json --role --active --eligible --help" ;;
        activate) opts="--tenant --json --role --all --justification --hours --yes --dry-run --max-parallel --help" ;;
        status|tenants) opts="--tenant --json --help" ;;
        completions) opts="zsh bash fish" ;;
        help) opts="list activate status tenants completions version" ;;
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
    complete -c pimento -n __fish_use_subcommand -a status -d 'Show your active roles'
    complete -c pimento -n __fish_use_subcommand -a tenants -d 'List the tenants your az login can reach'
    complete -c pimento -n __fish_use_subcommand -a completions -d 'Print a completion script'
    complete -c pimento -n __fish_use_subcommand -a version -d 'Print the version'
    complete -c pimento -n __fish_use_subcommand -a help -d 'Show help for a command'
    complete -c pimento -n '__fish_seen_subcommand_from list activate status tenants' -s t -l tenant -r -d 'Tenant GUID or domain'
    complete -c pimento -n '__fish_seen_subcommand_from list activate status tenants' -l json -d 'Machine-readable output'
    complete -c pimento -n '__fish_seen_subcommand_from list activate status tenants' -s h -l help -d 'Show help'
    complete -c pimento -n '__fish_seen_subcommand_from list activate' -l role -r -d 'Role name, * as wildcard'
    complete -c pimento -n '__fish_seen_subcommand_from list' -l active -d 'Only active roles'
    complete -c pimento -n '__fish_seen_subcommand_from list' -l eligible -d 'Only roles that are not active'
    complete -c pimento -n '__fish_seen_subcommand_from activate' -l all -d 'Every eligible role'
    complete -c pimento -n '__fish_seen_subcommand_from activate' -s j -l justification -r -d 'Justification'
    complete -c pimento -n '__fish_seen_subcommand_from activate' -l hours -x -a '1 2 4 8 12 24' -d 'Duration in hours'
    complete -c pimento -n '__fish_seen_subcommand_from activate' -s y -l yes -d 'Do not ask for confirmation'
    complete -c pimento -n '__fish_seen_subcommand_from activate' -l dry-run -d 'Print the requests, send nothing'
    complete -c pimento -n '__fish_seen_subcommand_from activate' -l max-parallel -x -d 'Requests in flight at once'
    complete -c pimento -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish'
    complete -c pimento -n '__fish_seen_subcommand_from help' -a 'list activate status tenants completions version'
    """#
}
