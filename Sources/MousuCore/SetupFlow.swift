/// First setup needs explicit continuation. Restoring permission after completed
/// setup resumes automatically without changing the user's saved choices.
public struct SetupFlow: Sendable {
    public private(set) var hasCompletedSetup: Bool
    public private(set) var permissionGranted: Bool
    public var automaticallySetUpDevices: Bool
    public var isPresented: Bool { !hasCompletedSetup || !permissionGranted }

    public init(
        hasCompletedSetup: Bool, permissionGranted: Bool, automaticallySetUpDevices: Bool = true
    ) {
        self.hasCompletedSetup = hasCompletedSetup
        self.permissionGranted = permissionGranted
        self.automaticallySetUpDevices = hasCompletedSetup ? automaticallySetUpDevices : true
    }

    public var canContinue: Bool { !hasCompletedSetup && permissionGranted }

    /// True once per restoration so the app can restart a permission-stopped tap.
    @discardableResult
    public mutating func updatePermission(_ granted: Bool) -> Bool {
        let resumed = hasCompletedSetup && !permissionGranted && granted
        permissionGranted = granted
        return resumed
    }

    public mutating func continueSetup() -> Bool {
        guard canContinue else { return false }
        hasCompletedSetup = true
        return true
    }
}
