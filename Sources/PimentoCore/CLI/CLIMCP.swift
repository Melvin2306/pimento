import Foundation

/// `pimento mcp`: a Model Context Protocol server on stdin/stdout for AI
/// agents (see `MCPServer`). It uses the CLI's auth source, services, presets
/// and history: reads go through GET-only services, and writes (only with
/// `--allow-activate`, and only after the user confirmed) are recorded in the
/// history with the source `mcp`.
extension CLIRunner {
    func mcp(_ o: MCPOptions) async throws -> CLIExit {
        var config = MCPConfiguration(allowActivate: o.allowActivate, allowPrivileged: o.allowPrivileged, noConfirm: o.noConfirm,
                                      tenant: o.tenant, demo: env.demo != nil)
        // Fail on a bad $PIMENTO_TENANT now, not on the first tool call.
        _ = try resolveTenant(o.tenant)
        if config.tenant == nil, let pinned = env.variables[CLIHelp.mcpTenantVariable]?.trimmingCharacters(in: .whitespaces), !pinned.isEmpty {
            guard TenantResolver.isValid(pinned) else { throw TenantError.invalid(pinned) }
            config.tenant = pinned
        }
        let backend = mcpBackend()
        let write = env.write
        let server = MCPServer(config: config, tools: MCPToolbox(backend: backend), clock: env.now,
                               send: { line in write(line + "\n", .out) },
                               log: { [self] line in err(line) })
        err(errStyle.dim("pimento mcp: Model Context Protocol on stdin/stdout, " + (config.allowActivate
            ? "activation allowed (each write is confirmed by the user\(config.noConfirm ? ", or by the client's own approval when it cannot ask" : ""))"
                + (config.allowPrivileged ? ", high-privilege roles allowed" : "")
            : "read-only") + (config.tenant.map { ", tenant \($0) only" } ?? "") + "."))
        await server.run(lines: Self.lines(from: env.readLine))
        return .success
    }

    /// The tools' access to Azure and Pimento's files, through this runner.
    func mcpBackend() -> MCPBackend {
        let runner = self
        let recorder = env.history.map { [now = env.now] in HistoryRecorder(store: $0, source: .mcp, clock: now) }
        return MCPBackend(
            service: { tenant, readOnly in
                runner.env.makeService(runner.auth.tokens(tenantId: tenant), readOnly).recording(to: readOnly ? nil : recorder)
            },
            tenants: { tenant in
                try await runner.env.loadTenants(tenant, runner.auth.source == .az ? nil : runner.auth.tokens(tenantId: tenant))
            },
            resolveTenant: { try runner.resolveTenant($0).tenantId },
            presets: PresetStore(environment: env.variables),
            history: env.history,
            now: env.now,
            timeZone: env.timeZone)
    }

    /// stdin, line by line, read on a thread of its own (`readLine` blocks).
    static func lines(from readLine: @escaping @Sendable () -> String?) -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }
}
