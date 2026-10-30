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
        case "keep-alive": keepAlive
        case "scheduled": scheduled
        case "cancel": cancel
        case "pending": pending
        case "wait": wait
        case "approvals": approvals
        case "approve": decide(.approve)
        case "deny": decide(.deny)
        case "status": status
        case "tenants": tenants
        case "presets": presets
        case "history": history
        case "completions": completions
        case "login": login
        case "logout": logout
        case "whoami": whoami
        case "mcp": mcp
        case "version": version
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
      keep-alive   Renew roles before they expire, during working hours (runs until Ctrl-C)
      scheduled    List your scheduled and pending activations
      cancel       Cancel scheduled or pending activations
      pending      List your requests waiting for approval
      wait         Wait until requests are approved or denied
      approvals    List requests you can approve or deny
      approve      Approve requests (asks first; --dry-run sends nothing)
      deny         Deny requests
      status       Show your active roles, soonest-expiring first
      tenants      List the tenants your az login can reach
      presets      List, show, save or delete saved role presets
      history      What Pimento sent, and how it went; export as CSV
      login        Sign in without the Azure CLI (browser, or --device-code)
      logout       Forget Pimento's sign-in
      whoami       Show the auth source and who you are signed in as
      mcp          Serve your roles to AI agents (Model Context Protocol, stdio)
      completions  Print a completion script for zsh, bash or fish
      version      Print the version; --check: is there a newer release?
      help         Show help for a command

    Common options:
    \(tenantOption)
          --json          Machine-readable output on stdout
          --auth SOURCE   az (your Azure CLI session) or pimento (`pimento login`).
                          Default: $\(AuthSourceResolver.environmentVariable), then the saved setting, then az.
          --demo          Demo mode: a simulated Azure with synthetic data; nothing is
                          sent and none of your files are used ($\(DemoMode.environmentVariable)=1)
      -h, --help          Show help

    By default Pimento uses your Azure CLI session (`az login`); with
    `pimento login` it signs in by itself (README › Pimento sign-in). Access
    tokens stay in memory and are only sent to management.azure.com; sign-in
    data only goes to login.microsoftonline.com.

    Exit codes: 0 ok, 1 something failed, 2 usage error, 3 az missing or not signed in,
    4 `wait` timed out. Run `pimento help <command>` for details.
    """

    static let list = """
    Usage: pimento list [FILTER…] [--role NAME] [--id ID] [--active | --eligible] [--tenant ID] [--json]

    Lists your eligible Azure-resource roles and whether they are active.

    Arguments:
      FILTER              Resource name contains FILTER (case-insensitive). Several
                          filters are OR-ed. A filter starting with / is an ARM scope
                          and matches it and everything below it.

    Options:
          --role NAME     Role name, case-insensitive, whole name; * is a wildcard
                          (--role owner, --role '*contributor'). Repeatable.
          --id ID         Exactly the role with this id or eligibilityScheduleId
                          (from --json). Repeatable.
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
          --id ID         Exactly the role with this id or eligibilityScheduleId
                          (from `pimento list --json`), for scripts. Repeatable.
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
          --at WHEN       Schedule the activation instead of starting it now (see
                          below). PIM accepts a start up to a month ahead
                          (Pimento: 30 days). A role still active at that time is
                          skipped; one that has ended by then is scheduled.
          --ticket NUMBER Ticket number sent with every request. Required (with a
                          ticket system) when a role's policy asks for a ticket:
                          without it activate stops with exit 2 and names them.
          --ticket-system NAME
                          Ticket system, e.g. ServiceNow (default: the preset's)
      -y, --yes           Don't ask. Required when stdin is not a terminal.
          --dry-run       Print the requests (PUT URL and body), send nothing
          --max-parallel N
                          Requests in flight at once, 1-\(ActivateOptions.maxParallelRange.upperBound) (default 8)
    \(tenantOption)
          --json          JSON: {dryRun, results: [...], summary: {...}}

    WHEN (local time unless a zone is given; case-insensitive):
      now                       right away (the default)
      +90m, +1h, +1h30m, +2d    from now
      08:00, 8:30, 8            the next time it is that time (today or tomorrow)
      today 17:00               today
      tomorrow 08:00            tomorrow (also tomorrow08:00)
      mon 08:00 … sunday 9:15   the next such day (today if the time is still ahead)
      workday 08:00             the next working day (Monday-Friday) after today
      2026-11-02 08:00          a local date and time (also 2026-11-02T08:00)
      2026-11-02T08:00:00Z      ISO 8601 with a zone (Z, +01:00, -0500)

    Pimento shows the plan, highlights Owner roles and asks before sending.
    A role whose policy requires approval is submitted and shows "awaiting
    approval" with its request id (exit code 0): nothing is active until an
    approver decides (24 hours at most). `pimento pending` lists such requests,
    `pimento wait --all` waits for the decision.
    Exit codes: 0 all activated, scheduled, awaiting approval or already active, 1 some failed (or
    you said no), 2 usage error (also: a ticket is required but missing),
    3 token missing or rejected.

    Examples:
      pimento activate prod --role Reader -j "INC-1234 look at logs" --hours 2
      pimento activate --all -j "on-call" --dry-run
      pimento activate --role owner contoso-dev -j "deploy" --yes --json
      pimento activate --preset On-call --hours max
      pimento activate contoso-dev --role Contributor -j "release" --at "tomorrow 08:00"
      pimento activate prod --role Owner -j "change" --ticket CHG-1001 --ticket-system ServiceNow
    """

    static let scheduled = """
    Usage: pimento scheduled [--tenant ID] [--json]

    Lists your activations that have not started yet: scheduled ones (status
    Granted until their start) and requests waiting for an approver. Read from
    Azure, so it includes requests made in the portal or the app. Read-only.

    Options:
    \(tenantOption)
          --json          JSON: {tenantId, user, requests: [{name, kind, status, start, end, …}]}

    ID is the start of the request id; `pimento cancel ID` cancels it.
    """

    static let cancel = """
    Usage: pimento cancel (REQUEST-ID… | FILTER… | --role NAME | --all) [options]

    Cancels scheduled activations and requests waiting for approval (POST
    …/roleAssignmentScheduleRequests/{id}/cancel). A role that already started
    is not affected: end it with `pimento deactivate`.

    Selection (at least one is required):
      REQUEST-ID          A request id from `pimento scheduled`, or its first
                          characters (at least 4). Only hex digits and dashes
                          make an id: it must match a request or it is not found.
      FILTER              Resource name contains FILTER (as in `pimento list`)
          --role NAME     Role name, whole name, * as wildcard. Repeatable.
          --all           Every scheduled or pending activation

    Options:
      -y, --yes           Don't ask. Required when stdin is not a terminal.
          --dry-run       Print the cancel requests, send nothing
    \(tenantOption)
          --json          JSON: {dryRun, results: [...], notFound, summary: {cancelled, failed, planned}}

    Exit codes: 0 all cancelled, 1 something failed or an id was not found
    (RequestCannotBeCancelled: it started, was cancelled or decided meanwhile),
    2 usage error, 3 token missing or rejected.

    Examples:
      pimento cancel 5f0c1d2e
      pimento cancel contoso-dev --yes
      pimento cancel --all --dry-run
    """

    static let pending = """
    Usage: pimento pending [--tenant ID] [--json]

    Lists your activation requests that wait for an approver, with how long ago
    you asked and when PIM lets them expire (24 hours after the request).
    Read-only. Decided requests drop off the list.

    Options:
    \(tenantOption)
          --json          JSON: {tenantId, user, requests: [{name, status, createdOn, expiresAt, …}]}

    ID is the start of the request id: `pimento wait ID` waits for the
    decision, `pimento cancel ID` withdraws the request.
    """

    static let wait = """
    Usage: pimento wait (REQUEST-ID… | --all) [--timeout DURATION] [--tenant ID] [--json]

    Waits until requests that need approval are decided, reading your requests
    every \(Int(WaitOptions.pollInterval)) seconds (read-only). Prints each decision as it comes:
    approved (with the end of the activation), denied (with the approver's
    justification when Azure shows it to you), expired or cancelled.

    Selection:
      REQUEST-ID          A request id from `pimento pending` or `activate`, or its
                          first characters (at least 4). A request that was
                          already decided is reported right away.
          --all           Every request of yours that waits for approval now

    Options:
          --timeout DURATION
                          Give up after this long: 30m (default), 2h, 1h30m, 90s;
                          a plain number is minutes. At most 24h.
    \(tenantOption)
          --json          JSON: {results: [{target, outcome, status, until, reviewer, …}], summary}

    Exit codes: 0 all approved, 1 any denied, expired, cancelled, failed or not
    found, 2 usage error, 3 token missing or rejected, 4 timed out (still waiting).

    Examples:
      pimento wait 7a1b2c3d
      pimento wait --all --timeout 2h && ./deploy.sh
    """

    static let approvals = """
    Usage: pimento approvals [--tenant ID] [--json]

    Lists the activation requests you can approve or deny as a PIM approver:
    requester, role, resource, duration, when it was asked, when it expires
    (24 hours after the request), justification and ticket. Read-only.
    Without approver permissions the list is simply empty.

    Options:
    \(tenantOption)
          --json          JSON: {available, note, requests: [{name, requester, roleName, …}]}

    `pimento approve ID -j TEXT` or `pimento deny ID -j TEXT` decides one.
    """

    static func decide(_ d: ApprovalDecision) -> String {
        let verb = d.command
        return """
        Usage: pimento \(verb) REQUEST-ID… -j TEXT [--yes] [--dry-run] [--tenant ID] [--json]

        \(d == .approve ? "Approves" : "Denies") requests you can decide as a PIM approver (see
        `pimento approvals`): a PATCH on the approval's open stage with
        reviewResult \(d.rawValue) and your justification. The first approver's
        decision counts. You cannot decide your own requests.

        Arguments:
          REQUEST-ID          A request id from `pimento approvals`, or its first
                              characters (at least 4). Several are decided together.
                              With --yes only whole ids (36 characters) are taken,
                              and each must match a request exactly.

        Options:
          -j, --justification TEXT
                              Why you \(verb) (required; the requester can see it)
          -y, --yes           Don't ask (whole request ids only). Required when stdin
                              is not a terminal.
              --dry-run       Print the requests (PATCH URL and body), send nothing
        \(tenantOption)
              --json          JSON: {decision, dryRun, results: [...], notFound, summary}

        Pimento lists the requests first\(d == .approve ? ", highlights Owner roles" : "") and asks.
        Exit codes: 0 all \(d.pastTense), 1 something failed, was not found or was
        decided meanwhile (or you said no), 2 usage error, 3 token missing or rejected.

        Examples:
          pimento \(verb) 5f0c1d2e -j "\(d == .approve ? "matches CHG-1001" : "use the staging subscription")"
          pimento \(verb) 5f0c1d2e-0000-4000-8000-000000000001 -j "batch" --yes --json
        """
    }

    static let deactivate = """
    Usage: pimento deactivate (FILTER… | --role NAME | --all | --preset NAME) [options]

    Ends the matching activations now (PIM's SelfDeactivate). Only active roles
    are considered. PIM refuses to end an activation in its first 5 minutes;
    such roles are reported with the time from which it is possible.

    Selection (at least one is required):
      FILTER              Resource name contains FILTER (as in `pimento list`)
          --role NAME     Role name, whole name, * as wildcard. Repeatable.
          --id ID         Exactly the role with this id or eligibilityScheduleId
                          (from `pimento list --json`), for scripts. Repeatable.
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

    Tickets: the new activation carries the ticket the current one was
    requested with (read from your requests), or --ticket. A role whose policy
    requires a ticket is skipped when neither is known.

    Selection: as for deactivate (FILTER…, --role, --id, --all, --preset).

    Options:
      -j, --justification TEXT
                          Why you need the roles (required unless the preset has one)
          --hours N|max   New duration, 1-\(ActivationRequestBuilder.maxHours) (default \(ActivationRequestBuilder.defaultHours)) or max; capped at
                          each role's policy maximum
          --ticket NUMBER Ticket for the new activations (default: the original
                          activation's ticket, when it had one)
          --ticket-system NAME
                          Ticket system (default: the preset's)
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

    static let keepAlive = """
    Usage: pimento keep-alive (FILTER… | --role NAME | --all | --preset NAME) [options]

    Keeps the matching roles active during working hours, until you stop it
    with Ctrl-C: shortly before an activation ends, Pimento schedules a new one
    (SelfActivate) that starts exactly when it ends, so there is no gap. Roles
    that match later (you activate one) are kept alive too; roles that are not
    active are not activated.

    Rules (the same as the app's Keep alive):
    - Only during working hours (--days, --window; your local time), and never
      past their end: the last renewal of the day is shortened to end with
      them, in whole hours, and skipped when not even an hour fits.
    - Each renewal asks for --hours (default: the longest each policy allows),
      capped at the policy maximum.
    - The new activation carries the justification and ticket of the one it
      continues; -j is used when that justification is unknown. A role whose
      policy requires a ticket that is not known is skipped.
    - Roles whose policy requires approval, or cannot be read, are left alone.
    - Roles that can grant access (Owner, User Access Administrator, RBAC
      Administrator) are kept alive only when confirmed: those listed at the
      prompt, or all with --yes. One that matches later without --yes is not.
    - What it sends is recorded in the history with the source keepAlive.
    - A role you end early is not brought back. One that lapsed (the computer
      slept, the network was down) is activated again inside working hours,
      with a gap.
    - Failures are retried after 1, 5 and 15 minutes, then left until the
      next working hours. Your roles are read at least every 10 minutes.

    Ctrl-C stops the loop. Continuations already scheduled still start: see
    `pimento scheduled`, and `pimento cancel` to withdraw them.

    Options:
          --days DAYS     Working days: mon-fri (default), mon,wed,fri, weekend, all
          --window FROM-TO
                          Working hours, local time (default 08:00-18:00; 22:00-06:00
                          runs overnight)
          --hours N|max   Each renewal's duration, 1-\(ActivationRequestBuilder.maxHours) or max (default: the preset's,
                          else max), capped at each role's policy maximum
      -j, --justification TEXT
                          Used when the justification of the activation is unknown
                          (default: the preset's)
      -y, --yes           Don't ask. Required when stdin is not a terminal.
          --dry-run       Show what would be kept alive and done now, send nothing
    \(tenantOption)

    Examples:
      pimento keep-alive contoso-dev --role Contributor
      pimento keep-alive --preset On-call --window 07:00-19:00 --yes
      pimento keep-alive --all --days mon-thu --dry-run
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
    account cache. Read-only. No tenants is not an error: exit 0, with a note
    on stderr (an empty list with --json).

    Options:
      -t, --tenant ID     Ask ARM with a token for this tenant (default: az's current one)
          --json          JSON: {tenants: [{id, displayName, defaultDomain, category}]}
    """

    static let presets = """
    Usage: pimento presets [list] [--tenant ID] [--json]
           pimento presets show NAME [--tenant ID] [--json]
           pimento presets save NAME (FILTER… | --role NAME…) [--exact] [-j TEXT] [--hours N|max]
                                [--ticket-system NAME] [--force]
           pimento presets delete NAME [--tenant ID]

    A preset is a named set of roles with an optional justification and duration,
    for `pimento activate --preset NAME`. The app and the CLI share the file
    \(PimentoPaths.displayFile("presets.json")) ($\(PresetStore.environmentVariable) overrides it).
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
          --ticket-system NAME
                          Default ticket system for `activate --ticket`
      -f, --force         Replace a preset with the same name
    \(tenantOption)
          --json          JSON output

    Examples:
      pimento presets save On-call prod --role Owner -j "on-call" --hours max
      pimento presets save Deploy contoso-dev --role Contributor --exact
      pimento activate --preset On-call --yes
    """

    static let history = """
    Usage: pimento history [WORD…] [--since WHEN] [--until WHEN] [--action NAME…] [--outcome NAME…]
                           [--tenant ID|NAME] [--limit N] [--json | --csv]
           pimento history export FILE.csv [same filters]
           pimento history import-azure [--since WHEN] [--tenant ID] [--json]
           pimento history clear [--yes]

    Pimento records every request it sends, from the app and from the CLI: activate,
    schedule, cancel, deactivate, renew, extend, approve and deny, with the time,
    tenant, role, resource, outcome (Azure's status or error code and a short message),
    duration, start, justification, ticket and request id. Never tokens or request bodies.
    The file is \(PimentoPaths.displayFile("history.jsonl")) (JSON Lines, mode 600,
    shared with the app; $\(HistoryStore.environmentVariable) points elsewhere). Recording and how long
    records are kept (30, 90, 365 days or forever) are set in the app (Settings › History).

    history lists the newest \(CLIRunner.historyTableLimit) records (all with --json or --csv), newest first.
    WORDs must all appear in the role, resource, justification, ticket, request id or message.

    export writes CSV (RFC 4180, UTF-8, CRLF, a header row; UTC and local times; fields
    starting with = + - @ get a leading ' so spreadsheets do not run them). FILE - is stdout.

    import-azure reads your own past requests from Azure (roleAssignmentScheduleRequests,
    asTarget(), read-only) and adds the ones the history does not have yet, as source
    azure: activity from the portal or other tools shows up too.

    Options:
          --since WHEN    7d, 24h, 30m, 2w, today, yesterday, 2026-10-01, "2026-10-01 08:00", ISO 8601
          --until WHEN    Same forms
          --action NAME   activate, schedule, cancel, deactivate, renew, extend, approve, deny.
                          Repeatable or comma-separated.
          --outcome NAME  succeeded, pending, skipped, failed, denied, canceled, expired
      -t, --tenant ID|NAME
                          Only this tenant (GUID or part of its name). For import-azure:
                          the tenant to read from, as for every other command.
      -n, --limit N       At most N records
          --json          JSON: {records: […], total, file}
          --csv           CSV on stdout
      -y, --yes           clear: do not ask

    Examples:
      pimento history --since 7d
      pimento history --action approve,deny --since 30d
      pimento history export ~/Desktop/pim-history.csv --since 2026-10-01
      pimento history import-azure --since 30d
    """

    static let login = """
    Usage: pimento login [--device-code] [--client-id ID] [--tenant ID] [--json]

    Signs in with Pimento's own sign-in (Microsoft identity platform), so the
    Azure CLI is not needed. Opens your browser (authorization code with PKCE,
    answer on http://localhost:<random port>); --device-code prints a code to
    enter on another device instead, for SSH sessions and headless machines.
    On Windows there is no browser sign-in yet: login always uses a device code.

    Afterwards Pimento sign-in is the auth source of the app and the CLI (the
    shared setting); `--auth az` or $\(AuthSourceResolver.environmentVariable)=az picks the Azure CLI again.

    Options:
          --device-code   Sign in with a code on another device
          --client-id ID  Application (client) ID of your app registration. Default:
                          $\(AuthSourceResolver.clientIdVariable), then the saved one (README › Pimento sign-in)
      -t, --tenant ID     Tenant to sign in to. Default: $\(TenantResolver.environmentVariable), then your home
                          tenant. Other tenants work without signing in again.
          --json          The account as JSON

    The refresh token is kept in the Keychain (service io.github.melvin2306.pimento)
    on macOS; with $\(TokenStores.storeVariable)=file, and on Linux and Windows, in
    \(FileTokenStore.displayLocation()) (less secure). Access tokens stay in memory.
    """

    static let logout = """
    Usage: pimento logout [--all] [--json]

    Forgets the signed-in account (the default one), or every account with
    --all: deletes its refresh token. With no account left, the Azure CLI is the
    auth source again. Your az session is not touched (use `az logout`).
    """

    static let whoami = """
    Usage: pimento whoami [--tenant ID] [--json] [--auth SOURCE]

    Shows the auth source and where that choice came from, who its token is
    for (name, object ID, tenant), and the accounts of Pimento's sign-in.
    Exit 3 when the source has no valid sign-in.
    """

    static let mcp = """
    Usage: pimento mcp [--allow-activate [--allow-privileged] [--no-confirm]] [--tenant ID]

    A Model Context Protocol server on stdin/stdout, for AI agents (Claude Code,
    Claude Desktop, Cursor, …). An MCP client starts it; it is not meant to be
    run by hand. Read-only by default: tenants, eligible and active roles with
    their policies, presets, requests awaiting approval, and the history.

    Options:
          --allow-activate    Also offer activate_roles, deactivate_roles and renew_roles.
                              Each call is shown to you and sent only after you confirm
                              it in the client (MCP elicitation).
          --allow-privileged  Also activate or renew Owner, User Access Administrator and
                              Role Based Access Control Administrator (refused otherwise).
          --no-confirm        When the client cannot ask you (no elicitation support),
                              write anyway and rely on the client's own tool approval.
                              Without it such clients cannot change roles. Clients that
                              can ask always ask.
      -t, --tenant ID         The only tenant tool calls may use ($\(mcpTenantVariable)).
          --demo              The offline demo (Contoso), to try it without Azure.

    Durations are capped at each role's policy maximum, a justification is
    required, and every write is recorded in the history (source `mcp`).
    Tokens and file paths never appear in tool results. Logs go to stderr.

    Claude Code:  claude mcp add pimento -- pimento mcp
    See README › AI agents (MCP) for other clients and the safety model.
    """

    /// `PIMENTO_MCP_TENANT`: the same as `pimento mcp --tenant`, for client
    /// configurations that set environment variables more easily than arguments.
    static let mcpTenantVariable = "PIMENTO_MCP_TENANT"

    static let version = """
    Usage: pimento version [--check] [--json]

    Prints the version.

    Options:
          --check         Also ask GitHub for the latest release and say how to
                          update when it is newer (re-run the installer). This is
                          the only command that contacts GitHub, and nothing is
                          downloaded or installed. Off in demo mode and with
                          \(UpdateCheck.disableVariable)=1.
          --json          JSON: {version, checked, latest, publishedAt,
                          updateAvailable, releasePage, diskImage, installCommand, error}

    Exit codes: 0 the check worked (also when a newer version exists), 1 it could
    not be made (offline, turned off, rate limit).
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
        'keep-alive:Renew roles before they expire, during working hours'
        'scheduled:List your scheduled and pending activations'
        'cancel:Cancel scheduled or pending activations'
        'pending:List your requests waiting for approval'
        'wait:Wait until requests are approved or denied'
        'approvals:List requests you can approve or deny'
        'approve:Approve requests'
        'deny:Deny requests'
        'status:Show your active roles, soonest-expiring first'
        'tenants:List the tenants your az login can reach'
        'presets:List, show, save or delete role presets'
        'history:What Pimento sent, and how it went; export as CSV'
        'login:Sign in without the Azure CLI'
        'logout:Forget Pimento sign-in'
        'whoami:Show the auth source and who you are signed in as'
        'mcp:Serve your roles to AI agents (MCP over stdio)'
        'completions:Print a completion script'
        'version:Print the version, or check for a newer one'
        'help:Show help for a command'
      )
      common=(
        '(-t --tenant)'{-t,--tenant}'[Tenant GUID or domain]:tenant: '
        '--json[Machine-readable output]'
        '--auth[Auth source]:source:(az pimento)'
        '--demo[Demo mode: simulated Azure, synthetic data]'
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
                '*--id[Exactly the role with this id]:id: ' \
                '(--eligible)--active[Only active roles]' \
                '(--active)--eligible[Only roles that are not active]' \
                '*:resource filter: ' ;;
            activate)
              _arguments -s $common \
                '*--role[Role name, * as wildcard]:role: ' \
                '*--id[Exactly the role with this id]:id: ' \
                '--all[Every eligible role]' \
                '(-j --justification)'{-j,--justification}'[Justification]:justification: ' \
                '--hours[Duration in hours, or max]:hours:(max 1 2 4 8 12 24)' \
                '--preset[Saved preset]:preset: ' \
                '--at[Start later]:when:(now +1h tomorrow08:00 workday08:00)' \
                '--ticket[Ticket number]:ticket: ' \
                '--ticket-system[Ticket system]:system: ' \
                '(-y --yes)'{-y,--yes}'[Do not ask for confirmation]' \
                '--dry-run[Print the requests, send nothing]' \
                '--max-parallel[Requests in flight at once]:count: ' \
                '*:resource filter: ' ;;
            cancel)
              _arguments -s $common \
                '*--role[Role name, * as wildcard]:role: ' \
                '--all[Every pending activation]' \
                '(-y --yes)'{-y,--yes}'[Do not ask for confirmation]' \
                '--dry-run[Print the requests, send nothing]' \
                '*:request id or resource filter: ' ;;
            deactivate|renew)
              _arguments -s $common \
                '*--role[Role name, * as wildcard]:role: ' \
                '*--id[Exactly the role with this id]:id: ' \
                '--all[Every active role]' \
                '(-j --justification)'{-j,--justification}'[Justification]:justification: ' \
                '--hours[New duration in hours, or max (renew)]:hours:(max 1 2 4 8 12 24)' \
                '--ticket[Ticket number (renew)]:ticket: ' \
                '--ticket-system[Ticket system (renew)]:system: ' \
                '--preset[Saved preset]:preset: ' \
                '(-y --yes)'{-y,--yes}'[Do not ask for confirmation]' \
                '--dry-run[Print the requests, send nothing]' \
                '--max-parallel[Requests in flight at once]:count: ' \
                '*:resource filter: ' ;;
            keep-alive)
              _arguments -s $common \
                '*--role[Role name, * as wildcard]:role: ' \
                '--all[Every role]' \
                '--preset[Saved preset]:preset: ' \
                '(-j --justification)'{-j,--justification}'[Justification when the activation'"'"'s is unknown]:justification: ' \
                '--hours[Duration of each renewal in hours, or max]:hours:(max 1 2 4 8 12 24)' \
                '--days[Working days]:days:(mon-fri mon-thu weekend all)' \
                '--window[Working hours]:window:(08:00-18:00 07:00-19:00)' \
                '(-y --yes)'{-y,--yes}'[Do not ask for confirmation]' \
                '--dry-run[Show what would be done, send nothing]' \
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
            status|tenants|scheduled|pending|approvals) _arguments -s $common ;;
            wait)
              _arguments -s $common \
                '--all[Every request waiting for approval]' \
                '--timeout[Give up after]:duration:(10m 30m 1h 2h)' \
                '*:request id: ' ;;
            approve|deny)
              _arguments -s $common \
                '(-j --justification)'{-j,--justification}'[Justification]:justification: ' \
                '(-y --yes)'{-y,--yes}'[Do not ask for confirmation]' \
                '--dry-run[Print the requests, send nothing]' \
                '*:request id: ' ;;
            presets)
              _arguments -s $common \
                '1:presets command:(list show save delete)' \
                '*--role[Role name, * as wildcard]:role: ' \
                '--exact[Store the matching roles, not the filters]' \
                '(-j --justification)'{-j,--justification}'[Default justification]:justification: ' \
                '--hours[Default duration]:hours:(max 1 2 4 8 12 24)' \
                '--ticket-system[Default ticket system]:system: ' \
                '(-f --force)'{-f,--force}'[Replace a preset with the same name]' \
                '*:name or filter: ' ;;
            history)
              _arguments -s $common \
                '1:history command:(export import-azure clear)' \
                '--since[Since]:when:(today yesterday 24h 7d 30d)' \
                '--until[Until]:when:(today yesterday)' \
                '*--action[Action]:action:(activate schedule cancel deactivate renew extend approve deny)' \
                '*--outcome[Outcome]:outcome:(succeeded pending skipped failed denied canceled expired)' \
                '(-n --limit)'{-n,--limit}'[At most N records]:count: ' \
                '--csv[CSV on stdout]' \
                '(-y --yes)'{-y,--yes}'[Do not ask (clear)]' \
                '*:word or file:_files' ;;
            login)
              _arguments -s $common \
                '--device-code[Sign in with a code on another device]' \
                '--client-id[Application (client) ID]:client id: ' ;;
            logout) _arguments -s $common '--all[Every account]' ;;
            whoami) _arguments -s $common ;;
            mcp)
              _arguments -s $common \
                '--allow-activate[Offer the activate, deactivate and renew tools]' \
                '--allow-privileged[Allow Owner and access administrator roles]' \
                '--no-confirm[Write without elicitation when the client cannot ask]' ;;
            version) _arguments -s '--check[Check for a newer release]' '--json[Machine-readable output]' '(- *)'{-h,--help}'[Show help]' ;;
            completions) _arguments '1:shell:(zsh bash fish)' ;;
            help) _arguments '1:command:(list activate deactivate renew extend keep-alive scheduled cancel pending wait approvals approve deny status tenants presets history login logout whoami mcp completions version)' ;;
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
        COMPREPLY=($(compgen -W "list activate deactivate renew extend keep-alive scheduled cancel pending wait approvals approve deny status tenants presets history login logout whoami mcp completions version help" -- "$cur"))
        return
      fi
      case "$prev" in
        -t|--tenant|-j|--justification|--role|--id|--max-parallel|--preset|--days|--ticket|--ticket-system|--client-id) return ;;
        --auth) COMPREPLY=($(compgen -W "az pimento" -- "$cur")); return ;;
        --at) COMPREPLY=($(compgen -W "now +1h +2h tomorrow08:00 workday08:00" -- "$cur")); return ;;
        --hours) COMPREPLY=($(compgen -W "max 1 2 4 8 12 24" -- "$cur")); return ;;
        --timeout) COMPREPLY=($(compgen -W "10m 30m 1h 2h" -- "$cur")); return ;;
        --since|--until) COMPREPLY=($(compgen -W "today yesterday 24h 7d 30d" -- "$cur")); return ;;
        --action) COMPREPLY=($(compgen -W "activate schedule cancel deactivate renew extend approve deny" -- "$cur")); return ;;
        --outcome) COMPREPLY=($(compgen -W "succeeded pending skipped failed denied canceled expired" -- "$cur")); return ;;
        -n|--limit) return ;;
      esac
      case "$cmd" in
        list) opts="--tenant --json --role --id --active --eligible --help" ;;
        activate) opts="--tenant --json --role --id --all --preset --justification --hours --at --ticket --ticket-system --yes --dry-run --max-parallel --help" ;;
        cancel) opts="--tenant --json --role --all --yes --dry-run --help" ;;
        deactivate) opts="--tenant --json --role --id --all --preset --justification --yes --dry-run --max-parallel --help" ;;
        renew) opts="--tenant --json --role --id --all --preset --justification --hours --ticket --ticket-system --yes --dry-run --max-parallel --help" ;;
        extend) opts="--tenant --json --role --all --justification --days --yes --dry-run --help" ;;
        keep-alive) opts="--tenant --role --all --preset --justification --hours --days --window --yes --dry-run --help" ;;
        status|tenants|scheduled|pending|approvals) opts="--tenant --json --help" ;;
        wait) opts="--tenant --json --all --timeout --help" ;;
        approve|deny) opts="--tenant --json --justification --yes --dry-run --help" ;;
        presets)
          if [[ $COMP_CWORD -eq 2 ]]; then opts="list show save delete"
          else opts="--tenant --json --role --exact --justification --hours --ticket-system --force --help"; fi ;;
        history)
          if [[ $COMP_CWORD -eq 2 ]]; then opts="export import-azure clear --since --until --action --outcome --tenant --limit --json --csv --help"
          else opts="--since --until --action --outcome --tenant --limit --json --csv --yes --help"; fi ;;
        login) opts="--tenant --json --auth --device-code --client-id --help" ;;
        logout) opts="--all --json --help" ;;
        whoami) opts="--tenant --json --auth --help" ;;
        mcp) opts="--tenant --allow-activate --allow-privileged --no-confirm --help" ;;
        version) opts="--check --json --help" ;;
        completions) opts="zsh bash fish" ;;
        help) opts="list activate deactivate renew extend keep-alive scheduled cancel pending wait approvals approve deny status tenants presets history login logout whoami mcp completions version" ;;
        *) opts="" ;;
      esac
      [[ "$cmd" != completions && "$cmd" != help && "$cmd" != logout ]] && opts="$opts --auth"
      [[ "$cmd" != completions && "$cmd" != help ]] && opts="$opts --demo"
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
    complete -c pimento -n __fish_use_subcommand -a keep-alive -d 'Renew roles before they expire, during working hours'
    complete -c pimento -n __fish_use_subcommand -a scheduled -d 'List your scheduled and pending activations'
    complete -c pimento -n __fish_use_subcommand -a cancel -d 'Cancel scheduled or pending activations'
    complete -c pimento -n __fish_use_subcommand -a pending -d 'List your requests waiting for approval'
    complete -c pimento -n __fish_use_subcommand -a wait -d 'Wait until requests are approved or denied'
    complete -c pimento -n __fish_use_subcommand -a approvals -d 'List requests you can approve or deny'
    complete -c pimento -n __fish_use_subcommand -a approve -d 'Approve requests'
    complete -c pimento -n __fish_use_subcommand -a deny -d 'Deny requests'
    complete -c pimento -n __fish_use_subcommand -a status -d 'Show your active roles'
    complete -c pimento -n __fish_use_subcommand -a tenants -d 'List the tenants your az login can reach'
    complete -c pimento -n __fish_use_subcommand -a presets -d 'List, show, save or delete role presets'
    complete -c pimento -n __fish_use_subcommand -a history -d 'What Pimento sent, and how it went; export as CSV'
    complete -c pimento -n __fish_use_subcommand -a login -d 'Sign in without the Azure CLI'
    complete -c pimento -n __fish_use_subcommand -a logout -d 'Forget Pimento sign-in'
    complete -c pimento -n __fish_use_subcommand -a whoami -d 'Show the auth source and who you are signed in as'
    complete -c pimento -n __fish_use_subcommand -a mcp -d 'Serve your roles to AI agents (MCP over stdio)'
    complete -c pimento -n __fish_use_subcommand -a completions -d 'Print a completion script'
    complete -c pimento -n __fish_use_subcommand -a version -d 'Print the version, or check for a newer one'
    complete -c pimento -n __fish_use_subcommand -a help -d 'Show help for a command'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew extend keep-alive scheduled cancel pending wait approvals approve deny status tenants presets history' -s t -l tenant -r -d 'Tenant GUID or domain'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew extend scheduled cancel pending wait approvals approve deny status tenants presets history' -l json -d 'Machine-readable output'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew extend keep-alive scheduled cancel pending wait approvals approve deny status tenants presets history' -s h -l help -d 'Show help'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew extend keep-alive cancel presets' -l role -r -d 'Role name, * as wildcard'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew' -l id -r -d 'Exactly the role with this id'
    complete -c pimento -n '__fish_seen_subcommand_from list' -l active -d 'Only active roles'
    complete -c pimento -n '__fish_seen_subcommand_from list' -l eligible -d 'Only roles that are not active'
    complete -c pimento -n '__fish_seen_subcommand_from activate' -l all -d 'Every eligible role'
    complete -c pimento -n '__fish_seen_subcommand_from deactivate renew extend keep-alive' -l all -d 'Every active role'
    complete -c pimento -n '__fish_seen_subcommand_from cancel' -l all -d 'Every pending activation'
    complete -c pimento -n '__fish_seen_subcommand_from activate' -l at -x -a 'now +1h +2h tomorrow08:00 workday08:00' -d 'Start later'
    complete -c pimento -n '__fish_seen_subcommand_from activate renew' -l ticket -r -d 'Ticket number'
    complete -c pimento -n '__fish_seen_subcommand_from activate renew presets' -l ticket-system -r -d 'Ticket system'
    complete -c pimento -n '__fish_seen_subcommand_from extend' -l days -x -a '7 30 90 180 365' -d 'Days to extend by'
    complete -c pimento -n '__fish_seen_subcommand_from keep-alive' -l days -x -a 'mon-fri mon-thu weekend all' -d 'Working days'
    complete -c pimento -n '__fish_seen_subcommand_from keep-alive' -l window -x -a '08:00-18:00 07:00-19:00' -d 'Working hours'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew extend keep-alive approve deny presets' -s j -l justification -r -d 'Justification'
    complete -c pimento -n '__fish_seen_subcommand_from activate renew keep-alive presets' -l hours -x -a 'max 1 2 4 8 12 24' -d 'Duration in hours, or max'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew keep-alive' -l preset -r -d 'Saved preset'
    complete -c pimento -n '__fish_seen_subcommand_from presets; and not __fish_seen_subcommand_from list show save delete' -a 'list show save delete'
    complete -c pimento -n '__fish_seen_subcommand_from presets' -l exact -d 'Store the matching roles, not the filters'
    complete -c pimento -n '__fish_seen_subcommand_from presets' -s f -l force -d 'Replace a preset with the same name'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew extend keep-alive cancel approve deny' -s y -l yes -d 'Do not ask for confirmation'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew extend keep-alive cancel approve deny' -l dry-run -d 'Print the requests, send nothing'
    complete -c pimento -n '__fish_seen_subcommand_from wait' -l all -d 'Every request waiting for approval'
    complete -c pimento -n '__fish_seen_subcommand_from wait' -l timeout -x -a '10m 30m 1h 2h' -d 'Give up after'
    complete -c pimento -n '__fish_seen_subcommand_from activate deactivate renew' -l max-parallel -x -d 'Requests in flight at once'
    complete -c pimento -n '__fish_seen_subcommand_from history; and not __fish_seen_subcommand_from export import-azure clear' -a 'export import-azure clear'
    complete -c pimento -n '__fish_seen_subcommand_from history' -l since -x -a 'today yesterday 24h 7d 30d' -d 'Since'
    complete -c pimento -n '__fish_seen_subcommand_from history' -l until -x -a 'today yesterday' -d 'Until'
    complete -c pimento -n '__fish_seen_subcommand_from history' -l action -x -a 'activate schedule cancel deactivate renew extend approve deny' -d 'Action'
    complete -c pimento -n '__fish_seen_subcommand_from history' -l outcome -x -a 'succeeded pending skipped failed denied canceled expired' -d 'Outcome'
    complete -c pimento -n '__fish_seen_subcommand_from history' -s n -l limit -x -d 'At most N records'
    complete -c pimento -n '__fish_seen_subcommand_from history' -l csv -d 'CSV on stdout'
    complete -c pimento -n '__fish_seen_subcommand_from history' -s y -l yes -d 'Do not ask (clear)'
    complete -c pimento -n '__fish_seen_subcommand_from list activate deactivate renew extend keep-alive scheduled cancel pending wait approvals approve deny status tenants presets history login whoami mcp' -l auth -x -a 'az pimento' -d 'Auth source'
    complete -c pimento -l demo -d 'Demo mode: simulated Azure, synthetic data'
    complete -c pimento -n '__fish_seen_subcommand_from login whoami' -s t -l tenant -r -d 'Tenant GUID or domain'
    complete -c pimento -n '__fish_seen_subcommand_from login logout whoami' -l json -d 'Machine-readable output'
    complete -c pimento -n '__fish_seen_subcommand_from login' -l device-code -d 'Sign in with a code on another device'
    complete -c pimento -n '__fish_seen_subcommand_from login' -l client-id -r -d 'Application (client) ID'
    complete -c pimento -n '__fish_seen_subcommand_from logout' -l all -d 'Every account'
    complete -c pimento -n '__fish_seen_subcommand_from mcp' -s t -l tenant -r -d 'The only tenant tool calls may use'
    complete -c pimento -n '__fish_seen_subcommand_from mcp' -l allow-activate -d 'Offer the activate, deactivate and renew tools'
    complete -c pimento -n '__fish_seen_subcommand_from mcp' -l allow-privileged -d 'Allow Owner and access administrator roles'
    complete -c pimento -n '__fish_seen_subcommand_from mcp' -l no-confirm -d 'Write without elicitation when the client cannot ask'
    complete -c pimento -n '__fish_seen_subcommand_from version' -l check -d 'Check for a newer release'
    complete -c pimento -n '__fish_seen_subcommand_from version' -l json -d 'Machine-readable output'
    complete -c pimento -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish'
    complete -c pimento -n '__fish_seen_subcommand_from help' -a 'list activate deactivate renew extend keep-alive scheduled cancel pending wait approvals approve deny status tenants presets history login logout whoami mcp completions version'
    """#
}
