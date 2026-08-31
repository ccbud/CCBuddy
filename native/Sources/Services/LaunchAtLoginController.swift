import ServiceManagement

struct LaunchAtLoginController {
    private let status: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(service: SMAppService = .mainApp) {
        status = { service.status }
        register = { try service.register() }
        unregister = { try service.unregister() }
    }

    /// Internal injection seam for deterministic startup and state-transition tests. Production
    /// callers use the SMAppService-backed initializer above.
    init(
        status: @escaping () -> SMAppService.Status,
        register: @escaping () throws -> Void,
        unregister: @escaping () throws -> Void
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
    }

    var isEnabled: Bool { status() == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        let currentStatus = status()
        if enabled {
            if currentStatus != .enabled { try register() }
        } else if currentStatus == .enabled || currentStatus == .requiresApproval {
            try unregister()
        }
    }

    /// Refresh an enabled login item after an application/bundle migration. Re-registering is
    /// deliberate: merely observing an enabled status can leave the service record pointing at
    /// the executable path from the prior Tauri bundle.
    func reconcileEnabledRegistration() throws {
        let currentStatus = status()
        if currentStatus == .enabled || currentStatus == .requiresApproval {
            try unregister()
        }
        try register()
    }
}
