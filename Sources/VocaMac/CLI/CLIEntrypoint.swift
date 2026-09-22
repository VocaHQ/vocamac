// CLIEntrypoint.swift
// VocaMac
//
// Process dispatcher and stdout-safe CLI execution.

import Darwin
import Foundation

/// Runs headless commands and emits stable JSON without constructing AppState.
final class CLIEntrypoint {
    typealias DataSink = (Data) -> Void

    private let headlessTranscriber: HeadlessTranscriber
    private let stdout: DataSink
    private let stderr: DataSink
    private let isolateOperationalStreams: Bool
    private let encoder: JSONEncoder

    init(
        headlessTranscriber: HeadlessTranscriber,
        stdout: @escaping DataSink = { FileHandle.standardOutput.write($0) },
        stderr: @escaping DataSink = { FileHandle.standardError.write($0) },
        isolateOperationalStreams: Bool = false
    ) {
        self.headlessTranscriber = headlessTranscriber
        self.stdout = stdout
        self.stderr = stderr
        self.isolateOperationalStreams = isolateOperationalStreams
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    /// Production dependencies intentionally include no AppState, audio input,
    /// hotkey, onboarding, text injection, or SwiftUI service.
    static func production() -> CLIEntrypoint {
        let modelManager = ModelManager()
        let preferences = AppCLIPreferencesReader()
        let transcriber = HeadlessTranscriber(
            modelManager: modelManager,
            preferences: preferences,
            audioLoader: AudioFileLoader(),
            transcriberFactory: { language in
                TranscriptionRouter(languagePreferenceProvider: { language })
            },
            // CoreML caches compiles per app, so a CLI load spares the app a
            // compile only when the CLI runs as the app's own binary.
            compiledModels: Bundle.main.bundleIdentifier == "com.vocamac.app"
                ? CompiledModelRecord()
                : nil
        )
        return CLIEntrypoint(
            headlessTranscriber: transcriber,
            isolateOperationalStreams: true
        )
    }

    /// Execute arguments excluding the executable path and return a process code.
    func run(arguments: [String]) async -> Int32 {
        let command: CLICommand
        do {
            command = try CLICommand.parse(arguments: arguments)
        } catch {
            return emit(error: error)
        }

        switch command {
        case .help:
            stdout(Data(Self.helpText.utf8))
            return 0
        case .listModels:
            return await runJSONOperation {
                self.headlessTranscriber.listModels()
            }
        case .transcribeFile(let path, let model, let language):
            return await runJSONOperation {
                try await self.headlessTranscriber.transcribe(
                    fileURL: URL(fileURLWithPath: path),
                    modelOverride: model,
                    languageOverride: language
                )
            }
        }
    }

    private func runJSONOperation<Response: Encodable>(
        _ operation: () async throws -> Response
    ) async -> Int32 {
        let isolatedStreams = isolateOperationalStreams ? beginStandardStreamIsolation() : nil
        defer { finishStandardStreamIsolation(isolatedStreams) }

        do {
            let response = try await operation()
            let data = try encodedLine(response)
            if let descriptor = isolatedStreams?.stdout {
                write(data, to: descriptor)
            } else {
                stdout(data)
            }
            return 0
        } catch {
            return emit(error: error, descriptor: isolatedStreams?.stderr)
        }
    }

    private func emit(error: Error, descriptor: Int32? = nil) -> Int32 {
        let cliError = error as? CLIError
            ?? CLIError(.transcriptionFailed, error.localizedDescription)
        VocaLogger.error(.general, "CLI \(cliError.category.rawValue): \(cliError.message)")

        do {
            let data = try encodedLine(CLIErrorResponse(
                error: cliError.category,
                message: cliError.message
            ))
            if let descriptor {
                write(data, to: descriptor)
            } else {
                stderr(data)
            }
        } catch {
            let fallback = Data("{\"error\":\"transcription_failed\",\"message\":\"Could not encode error response.\"}\n".utf8)
            if let descriptor {
                write(fallback, to: descriptor)
            } else {
                stderr(fallback)
            }
        }
        return cliError.exitCode
    }

    private func encodedLine<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private struct IsolatedStandardStreams {
        let stdout: Int32?
        let stderr: Int32?
    }

    /// Redirect process streams while engines run. JSON is written through a
    /// saved stdout descriptor, while categorized failures use saved stderr.
    /// This protects both contracts from direct third-party runtime logging.
    private func beginStandardStreamIsolation() -> IsolatedStandardStreams {
        Darwin.fflush(nil)
        return IsolatedStandardStreams(
            stdout: beginIsolation(of: STDOUT_FILENO),
            stderr: beginIsolation(of: STDERR_FILENO)
        )
    }

    private func beginIsolation(of descriptor: Int32) -> Int32? {
        let savedDescriptor = Darwin.dup(descriptor)
        guard savedDescriptor >= 0 else { return nil }

        let nullDescriptor = Darwin.open("/dev/null", O_WRONLY)
        guard nullDescriptor >= 0 else {
            Darwin.close(savedDescriptor)
            return nil
        }
        let result = Darwin.dup2(nullDescriptor, descriptor)
        Darwin.close(nullDescriptor)
        guard result >= 0 else {
            Darwin.close(savedDescriptor)
            return nil
        }
        return savedDescriptor
    }

    /// Production CLI mode exits immediately after `run` returns, so leave
    /// the process streams attached to /dev/null through teardown. CoreML can
    /// emit late background messages after transcription has returned.
    private func finishStandardStreamIsolation(_ streams: IsolatedStandardStreams?) {
        if let descriptor = streams?.stdout {
            Darwin.close(descriptor)
        }
        if let descriptor = streams?.stderr {
            Darwin.close(descriptor)
        }
    }

    private func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else { return }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    static let helpText = """
    VocaMac headless transcription

    Usage:
      VocaMac --transcribe-file <audio-path> --json [--model <id>] [--language <code>]
      VocaMac --list-models --json
      VocaMac --help

    Omitting --model and --language follows the current VocaMac app preferences.
    Models must already be downloaded; headless mode never opens the GUI or downloads models.
    """ + "\n"
}

/// The actual process entrypoint decides CLI versus GUI before SwiftUI can
/// construct `VocaMacApp` and its production AppState.
@main
enum VocaMacMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if CLICommand.invocationMode(arguments: arguments) == .cli {
            let exitCode = await CLIEntrypoint.production().run(arguments: arguments)
            Darwin.exit(exitCode)
        }

        VocaMacApp.main()
    }
}
