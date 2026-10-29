import Foundation

/// `pimento presets list|show|save|delete`. The presets file is shared with
/// the app; see `PresetStore`.
extension CLIRunner {
    func presets(_ command: PresetsCommand) async throws -> CLIExit {
        let store = PresetStore(environment: env.variables)
        switch command {
        case .list(let o): return try presetList(o, store: store)
        case .show(let o): return try presetShow(o, store: store)
        case .delete(let o): return try presetDelete(o, store: store)
        case .save(let o): return try await presetSave(o, store: store)
        }
    }

    func presetList(_ o: PresetListOptions, store: PresetStore) throws -> CLIExit {
        let library = try store.load()
        let tenantId = try resolveTenant(o.tenant).tenantId
        let presets = tenantId.map { library.presets(forTenant: $0) } ?? library.presets(forTenant: nil)
        if o.json {
            out(CLIJSON.encode(CLIJSON.PresetList(file: store.url.path, presets: presets.map(CLIJSON.PresetDoc.init))))
            return .success
        }
        guard !presets.isEmpty else {
            err(library.presets.isEmpty
                ? "No presets yet. Save one in the app, or with `pimento presets save NAME FILTER… [--role NAME]`."
                : "No presets for tenant \(tenantId ?? "").")
            if env.stderrIsTTY { err(errStyle.dim("File: \(store.url.path)")) }
            return .success
        }
        var table = TextTable(headers: ["NAME", "ROLES", "DURATION", "JUSTIFICATION", "TENANT"], flexible: [0, 3])
        for p in presets {
            table.append([
                .init(p.name),
                .init(p.summary, .dim),
                .init(p.duration?.label ?? "", .dim),
                .init(p.trimmedJustification ?? "", .dim),
                .init(p.tenantId.map { String($0.prefix(8)) } ?? "any", .dim),
            ])
        }
        table.render(style: outStyle, maxWidth: env.terminalWidth).forEach { out($0) }
        if env.stdoutIsTTY { out(outStyle.dim("\(CLIFormat.plural(presets.count, "preset")) · \(store.url.path)")) }
        return .success
    }

    func presetShow(_ o: PresetShowOptions, store: PresetStore) throws -> CLIExit {
        let preset = try store.load().find(o.name, tenantId: try resolveTenant(o.tenant).tenantId)
        if o.json {
            out(CLIJSON.encode(CLIJSON.PresetDoc(preset)))
            return .success
        }
        describe(preset).forEach { out($0) }
        return .success
    }

    func describe(_ p: Preset) -> [String] {
        var lines = [outStyle.bold(p.name) + outStyle.dim("  tenant \(p.tenantId ?? "any")")]
        lines.append("Duration: \(p.duration?.label ?? "not set (\(ActivationRequestBuilder.defaultHours) h unless --hours)")")
        lines.append("Justification: \(p.trimmedJustification ?? "not set (-j required)")")
        if !p.roles.isEmpty {
            lines.append("Roles:")
            var table = TextTable(headers: ["ROLE", "RESOURCE", "SCOPE"], flexible: [1, 2])
            for r in p.roles {
                table.append([
                    .init(r.roleName ?? RoleMatcher.lastPathComponent(r.roleDefinitionId)),
                    .init(r.scopeName ?? ""),
                    .init(r.scope, .dim),
                ])
            }
            table.render(style: outStyle, maxWidth: env.terminalWidth.map { $0 - 2 }).forEach { lines.append("  " + $0) }
        }
        if !p.match.isEmpty {
            lines.append("Rules (resolved when you activate):")
            for rule in p.match { lines.append("  " + rule.label) }
        }
        return lines
    }

    func presetDelete(_ o: PresetShowOptions, store: PresetStore) throws -> CLIExit {
        let tenantId = try resolveTenant(o.tenant).tenantId
        let (_, removed) = try store.update { library -> Preset in
            let p = try library.find(o.name, tenantId: tenantId)
            library.delete(p.id)
            return p
        }
        if o.json {
            out(CLIJSON.encode(CLIJSON.PresetDoc(removed)))
        } else {
            out("Deleted preset “\(removed.name)”.")
        }
        return .success
    }

    func presetSave(_ o: PresetSaveOptions, store: PresetStore) async throws -> CLIExit {
        // Load first: it fails before touching the roles when the file is
        // unreadable or from a newer version.
        _ = try store.load()
        let tenant = try resolveTenant(o.tenant)
        let snapshot: RoleSnapshot
        do { snapshot = try await load(tenant).1 } catch { return report(error, tenant: tenant.tenantId) }
        let matches = o.criteria.apply(snapshot.roles)
        var preset = Preset(
            name: o.name, tenantId: snapshot.identity.tenantId ?? tenant.tenantId,
            justification: o.justification?.nonEmpty, duration: o.duration)
        if o.exact {
            guard !matches.isEmpty else {
                err("No role matches, so there is nothing to save. `pimento list` shows what there is.")
                return .failure
            }
            var seen = Set<RoleMatcher.Key>()
            preset.roles = matches.filter { seen.insert($0.policyKey).inserted }.map(PresetRole.init)
        } else {
            preset.match = [PresetRule(filters: o.criteria.filters, roles: o.criteria.roles)]
        }
        let (_, saved) = try store.update { try $0.save(preset, replacing: o.force, now: env.now()) }
        if o.json {
            out(CLIJSON.encode(CLIJSON.PresetDoc(saved)))
            return .success
        }
        out("Saved preset “\(saved.name)” (\(saved.summary)) for tenant \(saved.tenantId ?? "any").")
        if matches.isEmpty {
            err(errStyle.yellow("note:") + " it matches no role right now.")
        } else {
            out(o.exact ? "It holds these roles:" : "It matches \(CLIFormat.plural(matches.count, "role")) now:")
            var table = TextTable(headers: ["ROLE", "RESOURCE", "TYPE"], flexible: [0, 1])
            for r in matches { table.append([.init(r.roleName, r.isOwner ? .strong : .plain), .init(r.scopeName), .init(r.scopeTypeLabel, .dim)]) }
            table.render(style: outStyle, maxWidth: env.terminalWidth.map { $0 - 2 }).forEach { out("  " + $0) }
        }
        out(outStyle.dim("Activate with: pimento activate --preset \(Self.shellQuote(saved.name))\(saved.trimmedJustification == nil ? " -j \"…\"" : "")"))
        return .success
    }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } ? s : "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
