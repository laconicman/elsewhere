import ArgumentParser
import ElsewhereKit
import Foundation

/// `elsewhere doctor` — the §5.7 check battery, redacted; exit 1 when any check fails.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check the engine, the config, each exit, and the generated Xray config — redacted."
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await exitingWithStatus { () async throws(ElsewhereError) -> Int32 in
            let checks = await Doctor.run(
                store: options.store,
                environment: ProcessInfo.processInfo.environment)
            for line in Doctor.lines(checks) { emit(line) }
            return checks.contains { $0.verdict == .failure } ? 1 : 0
        }
    }
}
