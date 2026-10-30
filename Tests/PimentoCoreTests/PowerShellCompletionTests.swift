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
                let accepted = contexts(command).contains { context in
                    let args = context + [flag] + (takesValue ? ["1"] : [])
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
}
