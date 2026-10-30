import Foundation
import Testing
@testable import PimentoCore

@Suite("CLI: PowerShell completions")
struct PowerShellCompletionTests {
    let script = CLIHelp.completionScript(for: .powershell)

    /// Parses `args`; nil when it parses, else the error.
    func parseError(_ args: [String]) -> CLIParseError? {
        do {
            _ = try CLIParser.parse(args)
            return nil
        } catch let error as CLIParseError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    /// The command lines a flag of `command` belongs to.
    func contexts(_ command: String) -> [[String]] {
        switch command {
        case "presets": [["presets", "save", "name", "x"], ["presets", "list"]]
        case "history": [["history"], ["history", "clear"], ["history", "import-azure"]]
        default: [[command]]
        }
    }

    @Test func theCommandAndShellNamesParse() throws {
        #expect(try CLIParser.parse(["completions", "powershell"]).command == .completions(.powershell))
        #expect(try CLIParser.parse(["completions", "pwsh"]).command == .completions(.powershell))
        #expect(throws: CLIParseError.unknownShell("cmd")) { try CLIParser.parse(["completions", "cmd"]) }
        #expect(CLIParseError.unknownShell("cmd").localizedDescription.contains("cmd has no programmable completion"))
        #expect(CLIHelp.text(for: "completions").contains("pimento completions powershell | Out-String | Invoke-Expression"))
        #expect(CLIHelp.text(for: "completions").contains("cmd.exe"))
        // The other shells offer powershell after `completions`.
        for shell in [CompletionShell.zsh, .bash, .fish] {
            #expect(CLIHelp.completionScript(for: shell).contains("zsh bash fish powershell"), "\(shell)")
        }
    }

    /// Windows PowerShell reads a profile without a byte order mark in the
    /// ANSI code page: the script (dot-sourced or Invoke-Expression'd from a
    /// profile) is ASCII, and generated the same way every time.
    @Test func theScriptIsASCIIAndRegistersANativeCompleter() {
        #expect(script.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(script == PowerShellCompletion.script)
        #expect(script.contains("Register-ArgumentCompleter -Native -CommandName 'pimento', 'pimento.exe' -ScriptBlock {"))
        #expect(script.hasSuffix("}"))
        // Balanced braces and parentheses: a cheap guard against a broken script.
        for (open, close) in [("{", "}"), ("(", ")")] {
            let code = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n")
            // Braces inside quoted strings (the quoting regex) are paired there too.
            #expect(code.components(separatedBy: open).count == code.components(separatedBy: close).count, "\(open)\(close)")
        }
        // Preset names come from the CLI's own JSON, offline.
        #expect(script.contains("@('presets', 'list', '--json')"))
        #expect(script.contains("ConvertFrom-Json"))
    }

    @Test func everyCommandIsCompleted() {
        #expect(CompletionSpec.commands.map(\.name) == CLICommand.names)
        for name in CLICommand.names {
            #expect(script.contains("'\(name)' = '"), "\(name)")
        }
        for command in CLICommand.names where command != "help" {
            #expect(CLIHelp.text(for: command).contains("Usage: pimento \(command)"), "\(command)")
        }
    }

    /// Every flag offered is one the parser takes for that command.
    @Test func everyFlagIsAcceptedByTheParser() {
        for (command, _) in CompletionSpec.commands {
            for flag in CompletionSpec.flags(of: command) where !["--help", "--auth", "--demo"].contains(flag) {
                let takesValue = CompletionSpec.valueFlags.contains(flag)
                // A value of the command's own kind where it has one (keep-alive --days mon-fri).
                // A domain for --tenant (`mcp` checks it while parsing).
                let value = CompletionSpec.commandValues.first { $0.command == command && $0.flag == flag }?.values.first
                    ?? (flag == "--tenant" ? "contoso.example" : "1")
                let accepted = contexts(command).contains { context in
                    let args = context + [flag] + (takesValue ? [value] : [])
                    if case .unknownOption = parseError(args) { return false }
                    return true
                }
                #expect(accepted, "pimento \(command) \(flag)")
            }
            #expect(Set(CompletionSpec.flags(of: command)).count == CompletionSpec.flags(of: command).count, "\(command)")
        }
    }

    /// Every long flag a command's help mentions is offered for it.
    @Test func everyFlagInTheHelpIsOffered() {
        let pattern = try! NSRegularExpression(pattern: "(?<![\\w-])--[a-z][a-z-]*[a-z]")
        for (command, _) in CompletionSpec.commands where !["help", "completions", "version"].contains(command) {
            let help = CLIHelp.text(for: command)
            let mentioned = Set(pattern.matches(in: help, range: NSRange(help.startIndex..., in: help)).map {
                String(help[Range($0.range, in: help)!])
            })
            let offered = Set(CompletionSpec.flags(of: command))
            for flag in mentioned.subtracting(offered) {
                // Only flags the parser does not take for this command (another command's, in the text) may be missing.
                let accepted = contexts(command).contains { context in
                    if case .unknownOption = parseError(context + [flag, "1"]) { return false }
                    return true
                }
                #expect(!accepted, "pimento \(command) \(flag) is in the help but not completed")
            }
        }
    }

    /// The flags whose next word is skipped as their value are exactly those that take one.
    @Test func valueFlagsAreTheFlagsThatTakeAValue() {
        var seen = Set<String>()
        for (command, _) in CompletionSpec.commands {
            for flag in CompletionSpec.flags(of: command) where flag != "--help" && !seen.contains(flag) {
                for context in contexts(command) {
                    let error = parseError(context + [flag])
                    if case .unknownOption = error { continue }
                    let needsValue = error == .missingValue(flag)
                    #expect(needsValue == CompletionSpec.valueFlags.contains(flag), "\(flag)")
                    seen.insert(flag)
                    break
                }
            }
        }
        // The short forms are skipped as well.
        for short in ["-t", "-j", "-n"] { #expect(CompletionSpec.valueFlags.contains(short)) }
    }

    /// The values offered for a flag are values the parser takes.
    @Test func everyOfferedValueParses() {
        let commandFor = ["--auth": ["list"], "--hours": ["activate", "--all", "-j", "x"], "--at": ["activate", "--all", "-j", "x"],
                          "--days": ["extend", "--all", "-j", "x"], "--timeout": ["wait", "--all"], "--since": ["history"],
                          "--until": ["history"], "--action": ["history"], "--outcome": ["history"]]
        for (flag, values) in CompletionSpec.values {
            let base = try! #require(commandFor[flag], "\(flag)")
            for value in values {
                let error = parseError(base + [flag, value])
                switch error {
                case .invalidHours, .invalidStart, .invalidDate, .unknownAction, .unknownOutcome, .invalidTimeout, .outOfRange,
                     .invalidNumber, .unknownOption, .missingValue:
                    Issue.record("\(flag) \(value): \(error!.localizedDescription)")
                default: break
                }
            }
            #expect(CompletionSpec.valueFlags.contains(flag), "\(flag)")
        }
        #expect(AuthSource.allCases.map(\.rawValue).sorted() == ["az", "pimento"])
        for (command, flag, values) in CompletionSpec.commandValues {
            for value in values {
                #expect(parseError([command, "--all", flag, value]) == nil, "\(command) \(flag) \(value)")
            }
            #expect(CompletionSpec.flags(of: command).contains(flag), "\(command) \(flag)")
            #expect(CompletionSpec.valueFlags.contains(flag), "\(flag)")
        }
    }

    /// The commands and flags of mcp, keep-alive, version --check and --id
    /// are in the PowerShell script as in the other shells'.
    @Test func theNewerCommandsAndFlagsAreCompleted() {
        #expect(script.contains("'mcp' = @('--tenant', '--allow-activate', '--allow-privileged', '--no-confirm'"))
        #expect(script.contains("'keep-alive' = @('--tenant', '--role', '--all', '--preset'"))
        #expect(script.contains("'keep-alive --days' = @('mon-fri', 'mon-thu', 'weekend', 'all')"))
        #expect(script.contains("'version' = @('--check', '--json', '--help')"))
        for command in ["list", "activate", "deactivate", "renew"] {
            #expect(CompletionSpec.flags(of: command).contains("--id"), "\(command)")
        }
        #expect(!CompletionSpec.flags(of: "keep-alive").contains("--id"))
        for shell in [CompletionShell.zsh, .bash, .fish] {
            let other = CLIHelp.completionScript(for: shell)
            for word in ["mcp", "keep-alive", "powershell", "--check", "--id", "--allow-activate", "--window"] {
                // fish names a long flag as `-l check`.
                let spelled = shell == .fish && word.hasPrefix("--") ? "-l " + word.dropFirst(2) : word
                #expect(other.contains(spelled), "\(shell): \(word)")
            }
        }
    }

    @Test func theWordsAfterACommandParse() throws {
        for (command, words) in CompletionSpec.subcommands {
            for word in words {
                switch command {
                case "presets":
                    let args = word == "list" ? ["presets", "list"] : ["presets", word, "name"] + (word == "save" ? ["x"] : [])
                    if case .unknownPresetCommand = parseError(args) { Issue.record("presets \(word)") }
                case "history":
                    let args = ["history", word] + (word == "export" ? ["x.csv"] : []) + (word == "clear" ? ["--yes"] : [])
                    #expect(parseError(args) == nil, "history \(word)")
                case "completions":
                    #expect(try CLIParser.parse(["completions", word]).command == .completions(try #require(CompletionShell(argument: word))))
                case "help":
                    #expect(try CLIParser.parse(["help", word]).command == .help(topic: word))
                default:
                    Issue.record("no check for \(command)")
                }
            }
        }
    }

    @Test func everyOfferedFlagHasADescription() {
        let described = Set(CompletionSpec.flagDescriptions.map(\.flag))
        for (command, _) in CompletionSpec.commands {
            for flag in CompletionSpec.flags(of: command) { #expect(described.contains(flag), "\(flag)") }
        }
        for flag in CompletionSpec.globalFlags { #expect(described.contains(flag), "\(flag)") }
    }

    @Test func quotingForPowerShell() {
        #expect(PowerShellCompletion.quote("o'brien") == "'o''brien'")
        #expect(PowerShellCompletion.list(["a", "b'c"]) == "@('a', 'b''c')")
        #expect(PowerShellCompletion.list([]) == "@()")
    }

    /// PowerShell takes U+2018-U+201B as single quotes and U+201C-U+201E as
    /// double quotes: a preset name with one (macOS types them for ' and ")
    /// is quoted, and its single ones doubled, or the completed line breaks
    /// out of the string. (scripts/test-install.ps1 runs it on Windows.)
    @Test func presetNamesWithTypographicQuotesAreQuoted() {
        #expect(script.contains(#"if ($text -match '[\s''"`$;,(){}|&<>@#\u2018-\u201E]') {"#))
        #expect(script.contains(#"$completion = "'" + ($text -replace '[''\u2018-\u201B]', '$0$0') + "'""#))
    }
}
