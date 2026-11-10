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
    /// `vocabulary` is the raw `--vocabulary` value (a file or a comma
    /// list), resolved by `CLIVocabulary` when the command runs.
    case transcribeFile(
        path: String, model: String?, language: String?,
        output: CLIOutputOptions = CLIOutputOptions(), vocabulary: String? = nil
    )
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
        var wantsText = false
        var outputPath: String?
        var wantsPieces = false
        var cleanupModel: CleanupModelKind?
        var pauseSeconds: Double?
        var minPieceSeconds: Double?
        var vocabulary: String?
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
                guard let seconds = Double(text), seconds > 0, seconds <= Self.maxPieceOptionSeconds else {
                    throw CLIError(
                        .invalidArguments,
                        "\(argument) needs a number of seconds above 0 and at most \(Int(Self.maxPieceOptionSeconds))."
                    )
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
            case "--vocabulary":
                guard vocabulary == nil else {
                    throw CLIError(.invalidArguments, "--vocabulary may only be provided once.")
                }
                vocabulary = try value(after: argument, in: arguments, index: &index)
            case "--json":
                guard !wantsJSON else {
                    throw CLIError(.invalidArguments, "--json may only be provided once.")
                }
                wantsJSON = true
            case "--text":
                guard !wantsText else {
                    throw CLIError(.invalidArguments, "--text may only be provided once.")
                }
                wantsText = true
            case "--output":
                guard outputPath == nil else {
                    throw CLIError(.invalidArguments, "--output may only be provided once.")
                }
                outputPath = try value(after: argument, in: arguments, index: &index)
            default:
                throw CLIError(.invalidArguments, "Unknown argument: \(argument)")
            }
            index += 1
        }

        guard !(wantsJSON && wantsText) else {
            throw CLIError(.invalidArguments, "Use either --json or --text, not both.")
        }
        guard wantsJSON || wantsText else {
            throw CLIError(.invalidArguments, "Headless commands require --json (or --text with --transcribe-file).")
        }
        guard wantsList != (audioPath != nil) else {
            throw CLIError(
                .invalidArguments,
                "Specify exactly one of --transcribe-file or --list-models."
            )
        }

        if wantsList {
            guard !wantsText, outputPath == nil else {
                throw CLIError(.invalidArguments, "--text and --output only apply to --transcribe-file.")
            }
            guard !wantsPieces, cleanupModel == nil, pauseSeconds == nil, minPieceSeconds == nil else {
                throw CLIError(.invalidArguments, "--pieces and its options only apply to --transcribe-file.")
            }
            guard model == nil, language == nil, vocabulary == nil else {
                throw CLIError(
                    .invalidArguments, "--model, --language, and --vocabulary only apply to --transcribe-file."
                )
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
            guard !wantsText, outputPath == nil else {
                throw CLIError(.invalidArguments, "--text and --output do not apply to --pieces.")
            }
            let defaults = StreamingCommitOptions()
            return .comparePieces(path: audioPath, model: model, language: language, options: PieceComparisonOptions(
                cleanupModel: cleanupModel,
                pauseSeconds: pauseSeconds ?? defaults.pauseSeconds,
                minPieceSeconds: minPieceSeconds ?? defaults.minPieceSeconds,
                vocabulary: vocabulary
            ))
        }
        return .transcribeFile(path: audioPath, model: model, language: language, output: CLIOutputOptions(
            format: wantsText ? .text : .json,
            path: outputPath
        ), vocabulary: vocabulary)
    }

    /// Longest pause or minimum piece accepted: past a recording's 30-minute
    /// limit it could never apply, and larger values overflow sample counts.
    static let maxPieceOptionSeconds = 1_800.0

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
    /// The raw `--vocabulary` value, resolved by `CLIVocabulary`.
    var vocabulary: String?
}

/// How `--transcribe-file` writes a successful result.
struct CLIOutputOptions: Equatable {
    /// `--json` writes the JSON object; `--text` writes only the transcript.
    enum Format: Equatable {
        case json
        case text
    }

    var format: Format = .json
    /// `--output <path>` writes the result to this file instead of stdout.
    var path: String?
}

/// Turns a `--vocabulary` value into the hint list engines read.
///
/// The value is a file when one exists at that path (terms one per line or
/// comma-separated), and otherwise a comma-separated list. A value that
/// names a `.txt` or `.csv` file that does not exist is an error rather than
/// a one-term list, so a typo in a path is not silently scored as a term.
enum CLIVocabulary {
    static func resolve(_ value: String?, fileManager: FileManager = .default) throws -> String {
        guard let value, !value.isEmpty else { return "" }
        let path = (value as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let text: String
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw CLIError(.invalidArguments, "Could not read vocabulary file: \(value)")
            }
        } else if ["txt", "csv"].contains((path as NSString).pathExtension.lowercased()) {
            throw CLIError(.invalidArguments, "Vocabulary file not found: \(value)")
        } else {
            text = value
        }
        return RecognitionHints.terms(from: text).joined(separator: ", ")
    }
}
