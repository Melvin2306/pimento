import Foundation
import PimentoCore

/// Read-only command-line mode, handy for scripting and for checking access.
/// It is wired to `ReadOnlyTransport`, so it cannot send a PUT.
enum CLI {
    static let usage = """
    \(AppInfo.name) \(AppInfo.version): \(AppInfo.tagline)

    Usage:
      pimento [--tenant ID]               open the app
      pimento --list [--tenant ID]        list eligible roles and whether they are active
      pimento --dry-run -j TEXT [--hours N] [--role NAME] [--tenant ID] [FILTER …]
                                          print the activation requests the app would
                                          send for the matching roles that are not active
      pimento --tenants                   list the tenants your az login can reach
      pimento --version | --help

    Options:
      -t, --tenant ID      tenant GUID or domain (default: $\(TenantResolver.environmentVariable),
                           then az's current tenant)
      -j, --justification  justification for the activation
      --hours N            activation duration, 1-\(ActivationRequestBuilder.maxHours) (default \(ActivationRequestBuilder.defaultHours))
      --role NAME          only roles whose name contains NAME (e.g. owner)
      FILTER               case-insensitive substrings of the resource name (OR-ed)

    Nothing in command-line mode writes to Azure. Activate from the app.
    """

    static func run(_ options: CLIOptions) async -> Int32 {
        switch options.mode {
        case .help, .app:
            print(usage)
            return 0
        case .version:
            print("\(AppInfo.name) \(AppInfo.version)")
            return 0
        case .tenants:
            return await printTenants()
        case .list, .dryRun:
            break
        }

        let selection: TenantSelection
        do {
            selection = try TenantResolver.resolve(commandLine: options.tenant, saved: nil)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 64
        }
        let service = PIMService(
            transport: ReadOnlyTransport(URLSessionTransport()),
            tokens: AzureCLITokenProvider(tenantId: selection.tenantId))
        let snapshot: RoleSnapshot
        do {
            snapshot = try await service.loadRoles()
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            if let azError = error as? AzureCLIError, azError.needsLogin {
                fputs("hint: \(AzureCLIError.loginCommand(tenant: selection.tenantId))\n", stderr)
            }
            return 1
        }

        if options.mode == .list {
            printTable(snapshot)
            return 0
        }
        return dryRun(snapshot, options)
    }

    static func dryRun(_ snapshot: RoleSnapshot, _ options: CLIOptions) -> Int32 {
        var selected = snapshot.roles
        if let roleFilter = options.roleFilter {
            selected = selected.filter { $0.roleName.lowercased().contains(roleFilter) }
        }
        if !options.filters.isEmpty {
            selected = selected.filter { r in options.filters.contains { r.scopeName.lowercased().contains($0) } }
        }
        for role in selected where role.isActive {
            print("skip  \(role.scopeName) / \(role.roleName): already active")
        }
        selected = selected.filter { !$0.isActive }
        do {
            let plans = try ActivationRequestBuilder.plan(
                selected, principalId: snapshot.identity.objectId,
                justification: options.justification, hours: options.hours)
            for plan in plans {
                print("# \(plan.role.scopeName) / \(plan.role.roleName)")
                print("PUT \(plan.url.absoluteString)")
                print(plan.prettyBody)
                print()
            }
            print("dry run: \(plans.count) request(s) built, none sent")
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 2
        }
    }

    static func printTenants() async -> Int32 {
        do {
            // GET-only transport: the ARM /tenants listing cannot write anything.
            let tenants = try await TenantDirectory.load(transport: ReadOnlyTransport(URLSessionTransport()))
            if tenants.isEmpty {
                print("az knows no tenants. Run `az login` first.")
                return 1
            }
            for t in tenants {
                print(t.id + "  " + ([t.name ?? "(unnamed)"] + [t.detail].compactMap { $0 }).joined(separator: "  "))
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func printTable(_ snapshot: RoleSnapshot) {
        let tenant = snapshot.identity.tenantId.map { " in tenant \($0)" } ?? ""
        print("Signed in as \(snapshot.identity.displayName)\(tenant)")
        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? String(s.prefix(n - 1)) + " " : s + String(repeating: " ", count: n - s.count)
        }
        print(pad("#", 4) + pad("Resource", 44) + pad("Type", 16) + pad("Role", 14) + pad("Membership", 32) + pad("Cond", 6) + "Status")
        for (i, r) in snapshot.roles.enumerated() {
            let status = r.isActive
                ? "Active until " + (r.activeUntil.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "?")
                : "Eligible"
            print(pad("\(i + 1)", 4) + pad(r.scopeName, 44) + pad(r.scopeTypeLabel, 16) + pad(r.roleName, 14)
                + pad(r.membership.label, 32) + pad(r.hasCondition ? "yes" : "", 6) + status)
        }
        let active = snapshot.roles.filter(\.isActive).count
        print("\(snapshot.roles.count) eligible, \(active) active")
    }
}
