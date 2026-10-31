import Foundation

/// What `pimento`'s completions offer: commands, each command's flags, the
/// values of flags that have a fixed set, and the words that follow a
/// command (`presets show`, `completions bash`). The PowerShell script is
/// generated from it; tests check it against the parser.
public enum CompletionSpec {
    /// Every command with its description, in `pimento help` order.
    public static let commands: [(name: String, description: String)] = [
        ("list", "List your eligible roles and whether they are active"),
        ("activate", "Activate eligible roles"),
        ("deactivate", "End active roles early"),
        ("renew", "End and activate roles again"),
        ("extend", "Ask an administrator to extend time-bound assignments"),
        ("keep-alive", "Renew roles before they expire, during working hours"),
        ("scheduled", "List your scheduled and pending activations"),
        ("cancel", "Cancel scheduled or pending activations"),
        ("pending", "List your requests waiting for approval"),
        ("wait", "Wait until requests are approved or denied"),
        ("approvals", "List requests you can approve or deny"),
        ("approve", "Approve requests"),
        ("deny", "Deny requests"),
        ("status", "Show your active roles, soonest-expiring first"),
        ("tenants", "List the tenants your az login can reach"),
        ("presets", "List, show, save or delete role presets"),
        ("history", "What Pimento sent, and how it went; export as CSV"),
        ("login", "Sign in without the Azure CLI"),
        ("logout", "Forget Pimento sign-in"),
        ("whoami", "Show the auth source and who you are signed in as"),
        ("mcp", "Serve your roles to AI agents (MCP over stdio)"),
        ("completions", "Print a completion script"),
        ("version", "Print the version, or check for a newer one"),
        ("help", "Show help for a command"),
    ]

    /// The long flags of each command (short forms are for typing). `--help`
    /// everywhere but `completions` and `help`; `--auth` and `--demo` are
    /// added much as the bash script does: `--auth` everywhere but
    /// `completions`, `help`, `version` and `logout`, `--demo` everywhere but
    /// `completions`, `help` and `version`.
    public static func flags(of command: String) -> [String] {
        let tenantJSON = ["--tenant", "--json"]
        var flags: [String] = switch command {
        case "list": tenantJSON + ["--role", "--id", "--active", "--eligible"]
        case "activate":
            tenantJSON + ["--role", "--id", "--all", "--preset", "--preset-id", "--justification", "--hours", "--at", "--ticket",
                          "--ticket-system", "--yes", "--dry-run", "--max-parallel"]
        case "deactivate": tenantJSON + ["--role", "--id", "--all", "--preset", "--justification", "--yes", "--dry-run", "--max-parallel"]
        case "renew":
            tenantJSON + ["--role", "--id", "--all", "--preset", "--justification", "--hours", "--ticket", "--ticket-system", "--yes",
                          "--dry-run", "--max-parallel"]
        case "extend": tenantJSON + ["--role", "--all", "--justification", "--days", "--yes", "--dry-run"]
        case "keep-alive":
            ["--tenant", "--role", "--all", "--preset", "--justification", "--hours", "--days", "--window", "--yes", "--dry-run"]
        case "cancel": tenantJSON + ["--role", "--all", "--yes", "--dry-run"]
        case "wait": tenantJSON + ["--all", "--timeout"]
        case "approve", "deny": tenantJSON + ["--justification", "--yes", "--dry-run"]
        case "presets": tenantJSON + ["--role", "--exact", "--justification", "--hours", "--ticket-system", "--force"]
        case "history": tenantJSON + ["--since", "--until", "--action", "--outcome", "--limit", "--csv", "--yes"]
        case "login": tenantJSON + ["--device-code", "--client-id"]
        case "logout": ["--all", "--json"]
        case "mcp": ["--tenant", "--allow-activate", "--allow-privileged", "--no-confirm"]
        case "version": ["--check", "--json"]
        case "scheduled", "pending", "approvals", "status", "tenants", "whoami": tenantJSON
        default: []
        }
        if !["completions", "help"].contains(command) { flags.append("--help") }
        if !["completions", "help", "version", "logout"].contains(command) { flags.append("--auth") }
        if !["completions", "help", "version"].contains(command) { flags.append("--demo") }
        return flags
    }

    /// Flags before the command (`pimento --demo list`).
    public static let globalFlags = ["--demo", "--auth", "--help"]

    /// Flags whose next word is their value (short forms too, to skip it).
    public static let valueFlags = [
        "--tenant", "-t", "--auth", "--role", "--preset", "--preset-id", "--justification", "-j", "--hours", "--at", "--ticket",
        "--ticket-system", "--max-parallel", "--days", "--timeout", "--since", "--until", "--action", "--outcome",
        "--limit", "-n", "--client-id", "--id", "--window",
    ]

    /// The values offered after a flag (the others take free text; `--preset`
    /// gets the names of the saved presets). `commandValues` wins for its command.
    public static let values: [(flag: String, values: [String])] = [
        ("--auth", ["az", "pimento"]),
        ("--hours", ["max", "1", "2", "4", "8", "12", "24"]),
        ("--at", ["now", "+1h", "+2h", "tomorrow08:00", "workday08:00"]),
        ("--days", ["7", "30", "90", "180", "365"]),
        ("--timeout", ["10m", "30m", "1h", "2h"]),
        ("--since", ["today", "yesterday", "24h", "7d", "30d"]),
        ("--until", ["today", "yesterday"]),
        ("--action", ["activate", "schedule", "cancel", "deactivate", "renew", "extend", "approve", "deny"]),
        ("--outcome", ["succeeded", "pending", "skipped", "failed", "denied", "canceled", "expired"]),
    ]

    /// Values of a flag that means something else for one command
    /// (`keep-alive --days` takes working days, `extend --days` a number).
    public static let commandValues: [(command: String, flag: String, values: [String])] = [
        ("keep-alive", "--days", ["mon-fri", "mon-thu", "weekend", "all"]),
        ("keep-alive", "--window", ["08:00-18:00", "07:00-19:00"]),
    ]

    /// The word right after a command.
    public static let subcommands: [(command: String, words: [String])] = [
        ("presets", ["list", "show", "save", "delete"]),
        ("history", ["export", "import-azure", "clear"]),
        ("completions", CompletionShell.allCases.map(\.rawValue)),
        ("help", commands.map(\.name).filter { $0 != "help" }),
    ]

    /// What each flag does, for the completion's tooltip.
    public static let flagDescriptions: [(flag: String, description: String)] = [
        ("--tenant", "Tenant GUID or domain"),
        ("--json", "Machine-readable output"),
        ("--auth", "Auth source: az or pimento"),
        ("--demo", "Demo mode: simulated Azure, synthetic data"),
        ("--help", "Show help"),
        ("--role", "Role name, * as wildcard"),
        ("--id", "Exactly the role with this id (from list --json)"),
        ("--active", "Only active roles"),
        ("--eligible", "Only roles that are not active"),
        ("--all", "Every matching role or request"),
        ("--preset", "Saved preset"),
        ("--preset-id", "Exactly the preset with this id (from presets list --json)"),
        ("--justification", "Justification"),
        ("--hours", "Duration in hours, or max"),
        ("--at", "Start later"),
        ("--ticket", "Ticket number"),
        ("--ticket-system", "Ticket system"),
        ("--yes", "Do not ask for confirmation"),
        ("--dry-run", "Print the requests, send nothing"),
        ("--max-parallel", "Requests in flight at once"),
        ("--days", "Days to extend by (keep-alive: working days)"),
        ("--window", "Working hours, FROM-TO"),
        ("--timeout", "Give up after"),
        ("--exact", "Store the matching roles, not the filters"),
        ("--force", "Replace a preset with the same name"),
        ("--since", "Since"),
        ("--until", "Until"),
        ("--action", "Action"),
        ("--outcome", "Outcome"),
        ("--limit", "At most N records"),
        ("--csv", "CSV on stdout"),
        ("--device-code", "Sign in with a code on another device"),
        ("--client-id", "Application (client) ID"),
        ("--allow-activate", "Offer the activate, deactivate and renew tools"),
        ("--allow-privileged", "Allow Owner and access administrator roles"),
        ("--no-confirm", "Write without elicitation when the client cannot ask"),
        ("--check", "Check for a newer release"),
    ]
}

/// The PowerShell completion script: a native argument completer for
/// `pimento` and `pimento.exe`, for Windows PowerShell 5.1 and PowerShell 7.
/// Preset names come from `pimento presets list --json` (offline) when a
/// `--preset` value or the name after `presets show|delete` is completed.
/// ASCII only: Windows PowerShell reads a profile without a byte order mark
/// in the ANSI code page.
public enum PowerShellCompletion {
    public static var script: String {
        let spec = CompletionSpec.self
        var lines = [
            "# PowerShell completion for pimento (Windows PowerShell 5.1 and PowerShell 7).",
            "# Install: add this line to your profile ($PROFILE):",
            "#   pimento completions powershell | Out-String | Invoke-Expression",
            "# The Windows installer (install.ps1) sets it up for you.",
            "Register-ArgumentCompleter -Native -CommandName 'pimento', 'pimento.exe' -ScriptBlock {",
            "    param($wordToComplete, $commandAst, $cursorPosition)",
            "    $commands = [ordered]@{",
        ]
        lines += spec.commands.map { "        \(quote($0.name)) = \(quote($0.description))" }
        lines += ["    }", "    $flags = @{"]
        lines += spec.commands.map { "        \(quote($0.name)) = \(list(spec.flags(of: $0.name)))" }
        lines += ["    }", "    $values = @{"]
        lines += spec.values.map { "        \(quote($0.flag)) = \(list($0.values))" }
        lines += ["    }", "    $commandValues = @{"]
        lines += spec.commandValues.map { "        \(quote($0.command + " " + $0.flag)) = \(list($0.values))" }
        lines += ["    }", "    $subcommands = @{"]
        lines += spec.subcommands.map { "        \(quote($0.command)) = \(list($0.words))" }
        lines += ["    }", "    $descriptions = @{"]
        lines += spec.flagDescriptions.map { "        \(quote($0.flag)) = \(quote($0.description))" }
        lines += [
            "    }",
            "    $globalFlags = \(list(spec.globalFlags))",
            "    $valueFlags = \(list(spec.valueFlags))",
        ]
        return (lines + [logic]).joined(separator: "\n")
    }

    /// A PowerShell single-quoted string.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    static func list(_ items: [String]) -> String { "@(" + items.map(quote).joined(separator: ", ") + ")" }

    /// Reads the line up to the cursor and offers what fits there.
    static let logic = #"""
        $ErrorActionPreference = 'SilentlyContinue'
        # The words before the one being completed, without pimento itself.
        $words = @($commandAst.CommandElements | Select-Object -Skip 1 |
            Where-Object { $_.Extent.EndOffset -lt $cursorPosition } | ForEach-Object { $_.Extent.Text })
        $command = $null
        $positionals = @()
        $tenant = $null
        $demo = $false
        $expectValue = $false
        $previous = $null
        foreach ($word in $words) {
            if ($expectValue) {
                if ($previous -eq '--tenant' -or $previous -eq '-t') { $tenant = $word -replace '^[''"]|[''"]$', '' }
                $expectValue = $false
                continue
            }
            $previous = $word
            if ($word -eq '--demo') { $demo = $true }
            elseif ($valueFlags -contains $word) { $expectValue = $true }
            elseif ($word.StartsWith('-')) { }
            elseif ($null -eq $command) { $command = $word }
            else { $positionals += $word }
        }
        # Preset names, from the presets file (offline; the same tenant and demo mode as the line).
        $presetNames = {
            $exe = $commandAst.GetCommandName()
            if (-not $exe) { $exe = 'pimento' }
            $arguments = @('presets', 'list', '--json')
            if ($demo) { $arguments += '--demo' }
            # Only a GUID or domain, as one argument: Windows PowerShell 5.1 passes an
            # embedded double quote unescaped, which could split it into more arguments.
            if ($tenant -match '^[A-Za-z0-9][A-Za-z0-9.-]*$') { $arguments += "--tenant=$tenant" }
            $savedExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
            try {
                $json = & $exe @arguments 2>$null | Out-String
                @((ConvertFrom-Json $json).presets | ForEach-Object { $_.name })
            } catch {
                @()
            } finally {
                if ($savedExitCode) { $global:LASTEXITCODE = $savedExitCode.Value }
            }
        }
        $current = "$wordToComplete"
        $kind = 'ParameterValue'
        $candidates = @()
        if ($expectValue) {
            if ($previous -eq '--preset') { $candidates = @(& $presetNames) }
            elseif ($commandValues.ContainsKey("$command $previous")) { $candidates = $commandValues["$command $previous"] }
            elseif ($values.ContainsKey($previous)) { $candidates = $values[$previous] }
        } elseif ($null -eq $command) {
            if ($current.StartsWith('-')) { $candidates = $globalFlags; $kind = 'ParameterName' }
            else { $candidates = @($commands.Keys) }
        } elseif (-not $current.StartsWith('-')) {
            $first = $null
            if ($positionals.Count -gt 0) { $first = $positionals[0] }
            if ($positionals.Count -eq 0 -and $subcommands.ContainsKey($command)) {
                $candidates = $subcommands[$command]
            } elseif ($command -eq 'presets' -and $positionals.Count -eq 1 -and @('show', 'delete', 'rm') -contains $first) {
                $candidates = @(& $presetNames)
            }
        }
        if ($candidates.Count -eq 0 -and -not $expectValue -and $null -ne $command -and $flags.Contains($command)) {
            $candidates = $flags[$command]
            $kind = 'ParameterName'
        }
        $prefix = $current -replace '^[''"]', ''
        foreach ($candidate in $candidates) {
            if ($null -eq $candidate) { continue }
            $text = [string]$candidate
            if (-not $text.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $completion = $text
            # PowerShell also takes U+2018-U+201B as single and U+201C-U+201E as
            # double quotes: they are quoted (and the single ones doubled) too.
            if ($text -match '[\s''"`$;,(){}|&<>@#\u2018-\u201E]') {
                $completion = "'" + ($text -replace '[''\u2018-\u201B]', '$0$0') + "'"
            }
            $tip = $text
            if ($kind -eq 'ParameterName' -and $descriptions.ContainsKey($text)) { $tip = $descriptions[$text] }
            elseif (($null -eq $command -or $command -eq 'help') -and $commands.Contains($text)) { $tip = $commands[$text] }
            [System.Management.Automation.CompletionResult]::new($completion, $text, $kind, $tip)
        }
    }
    """#
}
