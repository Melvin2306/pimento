import AppKit
import PimentoCore
import SwiftUI

/// Settings › Account: where tokens come from, the client ID of the app
/// registration, the signed-in accounts, Sign In / Sign Out.
struct AccountSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPaneContainer {
            SettingsColumns(leadingWidth: 236) {
                SettingsGroup("Sign in with") {
                    Picker("Sign in with", selection: source) {
                        ForEach(AuthSource.allCases, id: \.self) { s in Text(s.title).tag(s) }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .disabled(model.authSelection.isOverride || model.isActivating)
                    if model.authSelection.isOverride {
                        SettingsNote("This launch uses $\(AuthSourceResolver.environmentVariable), which takes precedence.")
                    }
                    SettingsNote(model.authSource == .az
                        ? "Uses your Azure CLI session (az login). Nothing is stored by Pimento."
                        : "Pimento signs in by itself with your app registration. No Azure CLI needed.")
                }
            } trailing: {
                SettingsGroup("Pimento sign-in") {
                    SettingsRow("Client ID") {
                        TextField("Client ID", text: $model.clientIdDraft, prompt: Text("00000000-0000-0000-0000-000000000000"))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .frame(maxWidth: 320)
                            .onSubmit { model.commitClientId() }
                            .onChange(of: model.clientIdDraft) { _, _ in
                                if model.clientIdProblem == nil { model.commitClientId() }
                            }
                        if let problem = model.clientIdProblem {
                            SettingsNote(problem, kind: .error)
                        } else if ProcessInfo.processInfo.environment[AuthSourceResolver.clientIdVariable] != nil {
                            SettingsNote("$\(AuthSourceResolver.clientIdVariable) is set and takes precedence.")
                        }
                    }
                    SettingsRow("Accounts", alignment: .top) {
                        if model.signedInAccounts.isEmpty {
                            Text("Not signed in").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.signedInAccounts) { account in
                                    AccountRow(account: account, isCurrent: account.id == model.currentAccount?.id)
                                }
                            }
                        }
                    }
                    SettingsRow {
                        HStack {
                            Button("Sign In…") { model.signInWithBrowser() }
                                .disabled(!model.canSignIn)
                                .help("Opens your browser to sign in with your Microsoft work account")
                            Button("Sign In with Code…") { model.signInWithDeviceCode() }
                                .disabled(!model.canSignIn)
                                .help("Shows a code to enter at microsoft.com/devicelogin on any device")
                            Spacer()
                            if model.signedInAccounts.count > 1 {
                                Button("Sign Out All") { model.signOutAll() }
                                    .disabled(model.isActivating)
                            }
                        }
                        SignInStatus()
                    }
                    SettingsRow {
                        HStack(spacing: 4) {
                            SettingsNote("Needs your own app registration (README › Pimento sign-in).")
                                .fixedSize()
                            InfoButton("Needs a public client app registration in Microsoft Entra ID (README › Pimento sign-in). "
                                + "The refresh token is kept in your Keychain, access tokens only in memory. "
                                + "Sign-in data goes only to login.microsoftonline.com, tokens only to management.azure.com.",
                                label: "About Pimento sign-in")
                        }
                    }
                }
                .environment(\.settingsLabelWidth, 68)
            }
        }
        .task { await model.reloadAccounts() }
        .sheet(isPresented: Binding(
            get: { model.showDeviceCodeSheet && !model.deviceCodeInMainWindow },
            set: { if !$0 { model.cancelSignIn() } })) { DeviceCodeSheet() }
    }

    private var source: Binding<AuthSource> {
        Binding(get: { model.authSource }, set: { model.setAuthSource($0) })
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: SignedInAccount
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isCurrent ? "Signed in as \(account.name ?? account.username ?? account.objectId)" : (account.name ?? account.username ?? account.objectId))
                    .lineLimit(1)
                Text([account.username, "tenant \(account.tenantId.prefix(8))…"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if isCurrent {
                Text("In use").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Use") { model.useAccount(account) }
                    .disabled(model.isActivating)
            }
            Button("Sign Out") { model.signOut(account) }
                .disabled(model.isActivating)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Waiting for the browser…" with Cancel, or the last error.
private struct SignInStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.signInState {
        case .browser:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the browser… Finish signing in there.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelSignIn() }
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .requestingCode, .deviceCode:
            EmptyView()
        }
    }
}

/// The device code flow: the code, Copy, Open Page, and a spinner until the
/// user has entered it on any device.
struct DeviceCodeSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in with a code").font(.headline)
            switch model.signInState {
            case .requestingCode:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting a code from Microsoft…").foregroundStyle(.secondary)
                }
            case .deviceCode(let challenge):
                Text("On this or any other device, open the page below and enter the code. "
                    + "Pimento continues by itself once you have signed in.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(challenge.verificationURL.absoluteString)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text(challenge.userCode)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .kerning(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Code \(challenge.userCode)")
                HStack {
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(challenge.userCode, forType: .string)
                    }
                    .themedButton(.secondary)
                    Button("Open Page") { AzureWebPage.open(challenge.verificationURL) }
                        .themedButton(.secondary)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to sign in (the code expires in \(challenge.expiresIn / 60) minutes)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .browser:
                EmptyView()
            }
            HStack {
                Spacer()
                Button(isFailed ? "Close" : "Cancel") { model.cancelSignIn() }
                    .themedButton(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .themedPageBackground()
    }

    private var isFailed: Bool {
        if case .failed = model.signInState { true } else { false }
    }
}

/// What the main window offers when nobody is signed in: the Azure CLI
/// command, and Pimento's own sign-in.
struct SignInChoices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            switch model.authSource {
            case .az:
                azCommand
                alternative("Or sign in without the Azure CLI:") {
                    Button("Use Pimento Sign-in…") {
                        if model.effectiveClientId != nil, !model.authSelection.isOverride {
                            model.setAuthSource(.pimento)
                            model.signInWithBrowser()
                        } else {
                            model.openAccountSettings()
                        }
                    }
                    .themedButton(.secondary)
                }
            case .pimento:
                pimentoSignIn
                alternative("Or use your Azure CLI session:") {
                    Button("Use Azure CLI") { model.setAuthSource(.az) }
                        .themedButton(.secondary)
                        .disabled(model.authSelection.isOverride)
                }
            }
        }
    }

    private var azCommand: some View {
        VStack(spacing: 8) {
            Text("Run this in a terminal, then press Retry:")
            HStack {
                Text(model.loginCommand)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.loginCommand, forType: .string)
                }
                .themedButton(.secondary)
                .accessibilityLabel("Copy login command")
            }
        }
    }

    @ViewBuilder private var pimentoSignIn: some View {
        VStack(spacing: 8) {
            if model.effectiveClientId == nil {
                Text("Set the client ID of your app registration to sign in.")
                Button("Account Settings…") { model.openAccountSettings() }
                    .themedButton(.primary())
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Sign in with your Microsoft work account:")
                HStack {
                    Button("Sign In…") { model.signInWithBrowser() }
                        .themedButton(.primary())
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSignIn)
                    Button("Sign In with Code…") { model.signInWithDeviceCode(inMainWindow: true) }
                        .themedButton(.secondary)
                        .disabled(!model.canSignIn)
                }
                if case .browser = model.signInState {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the browser…").foregroundStyle(.secondary)
                        Button("Cancel") { model.cancelSignIn() }.buttonStyle(.link)
                    }
                } else if case .failed(let message) = model.signInState {
                    Text(message).font(.callout).foregroundStyle(.red)
                        .multilineTextAlignment(.center).frame(maxWidth: 560)
                }
            }
        }
    }

    private func alternative<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            content()
        }
        .font(.callout)
    }
}
