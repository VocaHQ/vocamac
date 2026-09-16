// CLICommand.swift
// VocaMac
//
// Parses the one-shot, headless command-line interface before SwiftUI starts.

import Foundation

/// Determines whether process arguments belong to the GUI or headless CLI.
enum CLIInvocationMode: Equatable {
    case gui
    case cli
}

/// A validated VocaMac command-line operation.
enum CLICommand: Equatable {
    case help
    case transcribeFile(path: String, model: String?, language: String?)
    /// Decode a file whole and piece by piece (as "Process while speaking"
    /// would while recording), optionally cleaning both, and report timings.
    case comparePieces(path: String, model: String?, language: String?, options: PieceComparisonOptions)
    case listModels

    /// Flags that unambiguously request the headless CLI. Any other launch
    /// arguments (e.g. GUI-only `--restarted` from Settings → Debug → Restart)
    /// fall through to the normal SwiftUI app. Also used by
    /// `VocaMacApp.ensureSingleInstance()` to avoid killing an in-flight CLI job.
    static let cliFlags: Set<String> = [
        "--transcribe-file", "--list-models", "--help", "-h",
    ]

    /// Only dispatch to the headless CLI when a recognized CLI flag is present.
    /// This makes unknown/GUI-only arguments fail safely into the GUI instead
    /// of being rejected by the CLI parser before the app ever launches.
    static func invocationMode(arguments: [String]) -> CLIInvocationMode {
        arguments.contains(where: cliFlags.contains) ? .cli : .gui
    }

    /// Parse arguments excluding the executable path.
    static func parse(arguments: [String]) throws -> CLICommand {
        if arguments.contains("--help") || arguments.contains("-h") {
            return .help
        }

        var audioPath: String?
        var model: String?
        var language: String?
        var wantsList = false
        var wantsJSON = false
        var wantsPieces = false
        var cleanupModel: CleanupModelKind?
        var pauseSeconds: Double?
        var minPieceSeconds: Double?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--transcribe-file":
                guard audioPath == nil else {
                    throw CLIError(.invalidArguments, "--transcribe-file may only be provided once.")
                }
                audioPath = try value(after: argument, in: arguments, index: &index)
            case "--list-models":
                guard !wantsList else {
                    throw CLIError(.invalidArguments, "--list-models may only be provided once.")
                }
                wantsList = true
            case "--model":
                guard model == nil else {
                    throw CLIError(.invalidArguments, "--model may only be provided once.")
                }
                model = try value(after: argument, in: arguments, index: &index)
            case "--language":
                guard language == nil else {
                    throw CLIError(.invalidArguments, "--language may only be provided once.")
                }
                language = try value(after: argument, in: arguments, index: &index)
            case "--pieces":
                guard !wantsPieces else {
                    throw CLIError(.invalidArguments, "--pieces may only be provided once.")
                }
                wantsPieces = true
            case "--cleanup":
                guard cleanupModel == nil else {
                    throw CLIError(.invalidArguments, "--cleanup may only be provided once.")
                }
                let identifier = try value(after: argument, in: arguments, index: &index)
                guard let kind = CleanupModelKind(rawValue: identifier) else {
                    let known = CleanupModelKind.allCases.map(\.rawValue).joined(separator: ", ")
                    throw CLIError(.invalidArguments, "Unknown cleanup model: \(identifier). Known: \(known)")
                }
                cleanupModel = kind
            case "--pause-seconds", "--min-piece-seconds":
                let text = try value(after: argument, in: arguments, index: &index)
                guard let seconds = Double(text), seconds > 0, seconds.isFinite else {
                    throw CLIError(.invalidArguments, "\(argument) needs a positive number of seconds.")
                }
                if argument == "--pause-seconds" {
                    guard pauseSeconds == nil else {
                        throw CLIError(.invalidArguments, "--pause-seconds may only be provided once.")
                    }
                    pauseSeconds = seconds
                } else {
                    guard minPieceSeconds == nil else {
                        throw CLIError(.invalidArguments, "--min-piece-seconds may only be provided once.")
                    }
                    minPieceSeconds = seconds
                }
            case "--json":
                guard !wantsJSON else {
                    throw CLIError(.invalidArguments, "--json may only be provided once.")
                }
                wantsJSON = true
            default:
                throw CLIError(.invalidArguments, "Unknown argument: \(argument)")
            }
            index += 1
        }

        guard wantsJSON else {
            throw CLIError(.invalidArguments, "Headless commands require --json.")
        }
        guard wantsList != (audioPath != nil) else {
            throw CLIError(
                .invalidArguments,
                "Specify exactly one of --transcribe-file or --list-models."
            )
        }

        if wantsList {
            guard !wantsPieces, cleanupModel == nil, pauseSeconds == nil, minPieceSeconds == nil else {
                throw CLIError(.invalidArguments, "--pieces and its options only apply to --transcribe-file.")
            }
            guard model == nil, language == nil else {
                throw CLIError(.invalidArguments, "--model and --language only apply to --transcribe-file.")
            }
            return .listModels
        }

        guard let audioPath else {
            throw CLIError(.invalidArguments, "Missing value for --transcribe-file.")
        }
        if !wantsPieces, cleanupModel != nil || pauseSeconds != nil || minPieceSeconds != nil {
            throw CLIError(.invalidArguments, "--cleanup, --pause-seconds, and --min-piece-seconds require --pieces.")
        }
        if wantsPieces {
            let defaults = StreamingCommitOptions()
            return .comparePieces(path: audioPath, model: model, language: language, options: PieceComparisonOptions(
                cleanupModel: cleanupModel,
                pauseSeconds: pauseSeconds ?? defaults.pauseSeconds,
                minPieceSeconds: minPieceSeconds ?? defaults.minPieceSeconds
            ))
        }
        return .transcribeFile(path: audioPath, model: model, language: language)
    }

    private static func value(
        after argument: String,
        in arguments: [String],
        index: inout Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count,
              !arguments[valueIndex].hasPrefix("--"),
              !arguments[valueIndex].isEmpty else {
            throw CLIError(.invalidArguments, "Missing value for \(argument).")
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

/// Settings for `--transcribe-file … --pieces`.
struct PieceComparisonOptions: Equatable {
    var cleanupModel: CleanupModelKind?
    var pauseSeconds: Double
    var minPieceSeconds: Double
}
