import Foundation

/// Central gate for the CHIKA_DEBUG_* QA hooks used by the simulator screenshot CI.
///
/// App Store installs can't receive environment variables, so the hooks were runtime no-ops in
/// production anyway — but the code paths shouldn't ship in a store binary at all. They compile
/// only in Debug builds, or in Release builds made with
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) CHIKA_SIM_CHECK"` (the sim-check workflow).
enum ChikaDebug {
    static func env(_ key: String) -> String? {
        #if DEBUG || CHIKA_SIM_CHECK
        return ProcessInfo.processInfo.environment[key]
        #else
        return nil
        #endif
    }
}
