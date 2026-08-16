import Foundation

/// Where Ratbat's `os.Logger` output goes.
///
/// Test runs used to write to the *same* subsystem and categories as
/// production, with byte-identical message text. Since the durable
/// evidence store is the unified log, that meant the surviving record was
/// almost entirely manufactured by CI — and indistinguishable from the
/// real failures it mimics. Measured on the mac-mini over a two-hour
/// window: 23,056 lines under `se.jonasjohansson.ratbat`, every one of
/// them from `xctest`, none from the running app.
///
/// Splitting the subsystem keeps `log show --predicate 'subsystem ==
/// "se.jonasjohansson.ratbat"'` meaning "what the radio actually did".
public enum RatbatLog {
    public static let productionSubsystem = "se.jonasjohansson.ratbat"
    public static let testSubsystem = "se.jonasjohansson.ratbat.tests"

    /// The subsystem this process should log to.
    public static let subsystem: String = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ? testSubsystem
            : productionSubsystem
    }()
}
