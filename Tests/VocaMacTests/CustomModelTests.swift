// CustomModelTests.swift
// VocaMacTests
//
// Bring-your-own-model: the manifest's checks, importing into a registry
// in a temporary folder, the checksum, the community catalog's caching, and
// the CLI listing imported models.

import CryptoKit
import XCTest
@testable import VocaMac

// MARK: - Fixtures

enum CustomModelFixtures {
    static func temporaryDirectory(_ test: XCTestCase) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VocaMac-Custom-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static func write(_ manifest: CustomModelManifest, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(CustomModelManifest.fileName))
    }

    /// A folder WhisperKit's file checks accept: three compiled components
    /// and the tokenizer.
    static func whisperFolder(in parent: URL, id: String = "whisper-small-tamil", sha256: String? = nil) throws -> URL {
        let folder = parent.appendingPathComponent(id)
        for component in CustomModelManifest.whisperKitComponents {
            let directory = folder.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("weights"), withIntermediateDirectories: true)
            try Data("meta \(component)".utf8).write(to: directory.appendingPathComponent("metadata.json"))
            try Data("mil".utf8).write(to: directory.appendingPathComponent("model.mil"))
            try Data(repeating: 7, count: 32).write(to: directory.appendingPathComponent("weights/weight.bin"))
        }
        for file in CustomModelManifest.whisperKitTokenizerFiles {
            try Data("{}".utf8).write(to: folder.appendingPathComponent(file))
        }
        try write(CustomModelManifest(
            id: id, name: "Whisper Small Tamil", engine: .whisperKit, languages: ["ta"], sha256: sha256,
            source: "https://huggingface.co/example/whisper-small-tamil", license: "MIT"
        ), to: folder)
        return folder
    }

    static func ggufFolder(in parent: URL, id: String = "my-gguf", architecture: String = "qwen2") throws -> URL {
        let folder = parent.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ggufHeader(architecture: architecture).write(to: folder.appendingPathComponent("model.gguf"))
        try write(CustomModelManifest(id: id, name: "My GGUF", engine: .cleanup, gguf: "model.gguf"), to: folder)
        return folder
    }

    /// A GGUF header with only `general.architecture`.
    static func ggufHeader(architecture: String) -> Data {
        var data = Data("GGUF".utf8)
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func string(_ value: String) { u64(UInt64(value.utf8.count)); data.append(contentsOf: Array(value.utf8)) }
        u32(3); u64(0); u64(1)
        string("general.architecture"); u32(8); string(architecture)
        return data
    }
}

// MARK: - Manifest

final class ModelManifestTests: XCTestCase {
    func testDecodesTheDocumentedExampleWithDefaults() throws {
        let json = """
        {"id":"whisper-small-tamil","name":"Whisper Small Tamil","engine":"whisperKit",
         "languages":["ta"],"fileSizeBytes":253000000,"sha256":"\(String(repeating: "a", count: 64))",
         "source":"https://huggingface.co/x","license":"MIT"}
        """
        let manifest = try JSONDecoder().decode(CustomModelManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.engine, .whisperKit)
        XCTAssertEqual(manifest.languages, ["ta"])
        XCTAssertEqual(manifest.fileSizeBytes, 253_000_000)

        let minimal = try JSONDecoder().decode(
            CustomModelManifest.self, from: Data(#"{"id":"m1","name":"M","engine":"cleanup","gguf":"m.gguf"}"#.utf8)
        )
        XCTAssertEqual(minimal.languages, [])
        XCTAssertNil(minimal.sha256)
    }

    func testIDsMustBeSafeAndNotABuiltInModel() {
        XCTAssertTrue(CustomModelManifest.isValidID("whisper-small-tamil"))
        XCTAssertTrue(CustomModelManifest.isValidID("m1.v2_q8"))
        XCTAssertFalse(CustomModelManifest.isValidID("Whisper"))
        XCTAssertFalse(CustomModelManifest.isValidID("../escape"))
        XCTAssertFalse(CustomModelManifest.isValidID("a"))
        XCTAssertFalse(CustomModelManifest.isValidID("-leading"))
        XCTAssertFalse(CustomModelManifest.isValidID("tiny"), "A built-in id would shadow the catalog")
        XCTAssertFalse(CustomModelManifest.isValidID("custom-whisperkit"))
        XCTAssertFalse(CustomModelManifest.isValidID("qwen25_0_5b_q4_k_m"))
    }

    func testAValidWhisperFolderHasNoProblems() throws {
        let folder = try CustomModelFixtures.whisperFolder(in: CustomModelFixtures.temporaryDirectory(self))
        let manifest = try CustomModelRegistry.readManifest(in: folder)
        XCTAssertEqual(manifest.problems(in: folder), [])
    }

    func testMissingFilesAreNamed() throws {
        let folder = try CustomModelFixtures.whisperFolder(in: CustomModelFixtures.temporaryDirectory(self))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("AudioEncoder.mlmodelc/weights"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("tokenizer.json"))
        let problems = try CustomModelRegistry.readManifest(in: folder).problems(in: folder)
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems[0].contains("AudioEncoder.mlmodelc"))
        XCTAssertTrue(problems[1].contains("tokenizer.json"))
    }

    func testSherpaModelsNeedAKnownTypeAndItsFiles() throws {
        let folder = CustomModelFixtures.temporaryDirectory(self).appendingPathComponent("ctc")
        var manifest = CustomModelManifest(id: "ctc-model", name: "CTC", engine: .sherpaOnnx)
        try CustomModelFixtures.write(manifest, to: folder)
        XCTAssertTrue(manifest.problems(in: folder).first?.contains("sherpa") ?? false)

        manifest.sherpa = .init(type: "transducer", model: "model.onnx")
        XCTAssertTrue(manifest.problems(in: folder).first?.contains("unknown") ?? false)

        manifest.sherpa = .init(type: "nemoCtc", model: "model.onnx")
        XCTAssertEqual(manifest.problems(in: folder), ["tokens.txt is missing.", "model.onnx is missing."])

        try Data("t".utf8).write(to: folder.appendingPathComponent("tokens.txt"))
        try Data("m".utf8).write(to: folder.appendingPathComponent("model.onnx"))
        XCTAssertEqual(manifest.problems(in: folder), [])
    }

    func testSherpaFileNamesStayInsideTheFolder() throws {
        let folder = CustomModelFixtures.temporaryDirectory(self).appendingPathComponent("escape")
        var manifest = CustomModelManifest(id: "escape-model", name: "Escape", engine: .sherpaOnnx)
        try CustomModelFixtures.write(manifest, to: folder)
        for name in ["../model.onnx", "/etc/model.onnx", "~/model.onnx", "sub/../../model.onnx"] {
            manifest.sherpa = .init(type: "nemoCtc", model: name)
            XCTAssertEqual(manifest.problems(in: folder), ["“\(name)” must name a file inside the model's folder."], name)
        }
        XCTAssertTrue(CustomModelManifest.isInsideFolder("tokenizer/vocab.json"))
    }

    func testHybridGGUFArchitecturesAreRefused() throws {
        let parent = CustomModelFixtures.temporaryDirectory(self)
        let refused = try CustomModelFixtures.ggufFolder(in: parent, id: "qwen35-small", architecture: "qwen35")
        let problems = try CustomModelRegistry.readManifest(in: refused).problems(in: refused)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("qwen35"))

        let fine = try CustomModelFixtures.ggufFolder(in: parent, id: "qwen2-small", architecture: "qwen2")
        XCTAssertEqual(try CustomModelRegistry.readManifest(in: fine).problems(in: fine), [])
    }

    func testAFileThatIsNotGGUFIsRefused() throws {
        let folder = try CustomModelFixtures.ggufFolder(in: CustomModelFixtures.temporaryDirectory(self))
        try Data("not a model".utf8).write(to: folder.appendingPathComponent("model.gguf"))
        let problems = try CustomModelRegistry.readManifest(in: folder).problems(in: folder)
        XCTAssertTrue(problems.first?.contains("not a readable GGUF") ?? false)
    }

    func testMalformedManifestSaysWhatIsMissing() throws {
        let folder = CustomModelFixtures.temporaryDirectory(self)
        try Data(#"{"id":"x1","engine":"whisperKit"}"#.utf8).write(to: folder.appendingPathComponent(CustomModelManifest.fileName))
        XCTAssertThrowsError(try CustomModelRegistry.readManifest(in: folder)) { error in
            XCTAssertEqual(error as? CustomModelError, .manifestUnreadable("“name” is missing."))
        }
    }
}

// MARK: - Importing

final class ModelManagerCustomImportTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VocaMac-CustomImport-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeManager() -> (ModelManager, CustomModelRegistry, URL) {
        let base = CustomModelFixtures.temporaryDirectory(self)
        let registry = CustomModelRegistry(root: base.appendingPathComponent("installed"), defaults: defaults)
        return (ModelManager(customModels: registry), registry, base.appendingPathComponent("sources"))
    }

    func testImportCopiesTheFolderAndRecordsItsSize() async throws {
        let (manager, registry, sources) = makeManager()
        let source = try CustomModelFixtures.whisperFolder(in: sources)
        let installed = try await manager.importCustomModel(from: source)

        XCTAssertEqual(
            installed.directory.resolvingSymlinksInPath().path,
            registry.root.appendingPathComponent("whisper-small-tamil").resolvingSymlinksInPath().path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "The original stays where it was")
        XCTAssertGreaterThan(installed.manifest.fileSizeBytes ?? 0, 0)
        XCTAssertEqual(manager.importedModels().map(\.id), ["whisper-small-tamil"])
        XCTAssertEqual(registry.activeModel(for: .whisperKit)?.id, "whisper-small-tamil", "The only model of its engine is active")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: registry.root.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "No staging folders are left behind")
    }

    func testAMatchingChecksumIsAcceptedAndAWrongOneRefused() async throws {
        let (manager, registry, sources) = makeManager()
        let source = try CustomModelFixtures.whisperFolder(in: sources)
        let digest = try CustomModelDigest.folderDigest(at: source)

        let wrong = try CustomModelFixtures.whisperFolder(in: sources.appendingPathComponent("wrong"), sha256: String(repeating: "0", count: 64))
        do {
            _ = try await manager.importCustomModel(from: wrong)
            XCTFail("A wrong checksum must be refused")
        } catch let error as CustomModelError {
            guard case .checksumMismatch(_, let actual) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(actual, digest, "The digest ignores vocamodel.json, so both folders hash the same")
        }
        XCTAssertTrue(registry.installedModels().isEmpty)

        let right = try CustomModelFixtures.whisperFolder(in: sources.appendingPathComponent("right"), sha256: digest)
        let installed = try await manager.importCustomModel(from: right)
        XCTAssertTrue(installed.isVerified)
    }

    func testTheFolderDigestMatchesTheDocumentedShellCommand() throws {
        let folder = try CustomModelFixtures.whisperFolder(in: CustomModelFixtures.temporaryDirectory(self))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "find . -type f ! -name vocamodel.json ! -name '.*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256"]
        process.currentDirectoryURL = folder
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let shell = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: " ").first.map(String.init)
        XCTAssertEqual(try CustomModelDigest.folderDigest(at: folder), shell)
    }

    func testAGGUFChecksumIsTheFileHash() async throws {
        let (manager, _, sources) = makeManager()
        let folder = try CustomModelFixtures.ggufFolder(in: sources)
        let hash = SHA256.hash(data: try Data(contentsOf: folder.appendingPathComponent("model.gguf")))
            .map { String(format: "%02x", $0) }.joined()
        var manifest = try CustomModelRegistry.readManifest(in: folder)
        manifest.sha256 = hash
        try CustomModelFixtures.write(manifest, to: folder)
        let installed = try await manager.importCustomModel(from: folder)
        XCTAssertEqual(installed.ggufURL?.lastPathComponent, "model.gguf")
    }

    func testDuplicateIDsAreRefused() async throws {
        let (manager, _, sources) = makeManager()
        _ = try await manager.importCustomModel(from: CustomModelFixtures.whisperFolder(in: sources))
        do {
            _ = try await manager.importCustomModel(from: CustomModelFixtures.whisperFolder(in: sources.appendingPathComponent("again")))
            XCTFail("A second model with the same id must be refused")
        } catch {
            XCTAssertEqual(error as? CustomModelError, .duplicateID("whisper-small-tamil"))
        }
    }

    func testAManifestInsideOneSubfolderIsFound() async throws {
        let (manager, _, sources) = makeManager()
        let wrapper = sources.appendingPathComponent("download")
        _ = try CustomModelFixtures.whisperFolder(in: wrapper)
        let installed = try await manager.importCustomModel(from: wrapper)
        XCTAssertEqual(installed.id, "whisper-small-tamil")
    }

    func testImportFromAZip() async throws {
        let (manager, _, sources) = makeManager()
        let folder = try CustomModelFixtures.whisperFolder(in: sources)
        let zip = sources.appendingPathComponent("model.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        let installed = try await manager.importCustomModel(from: zip)
        XCTAssertEqual(installed.id, "whisper-small-tamil")
    }

    func testDeleteRemovesTheFilesAndForgetsTheChoice() async throws {
        let (manager, registry, sources) = makeManager()
        let first = try await manager.importCustomModel(from: CustomModelFixtures.ggufFolder(in: sources, id: "first-gguf"))
        _ = try await manager.importCustomModel(from: CustomModelFixtures.ggufFolder(in: sources, id: "second-gguf"))
        XCTAssertNil(registry.activeModel(for: .cleanup), "Two models and no choice: nothing is guessed")
        try manager.activateCustomModel(id: "first-gguf", persist: true)
        XCTAssertEqual(registry.activeModel(for: .cleanup)?.id, "first-gguf")

        try await manager.deleteCustomModel(id: "first-gguf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertNil(defaults.string(forKey: CustomModelRegistry.activeKey(for: .cleanup)))
        XCTAssertEqual(registry.activeModel(for: .cleanup)?.id, "second-gguf", "The one left takes over")
    }

    func testAProcessOnlyChoiceIsNotSaved() async throws {
        let (manager, registry, sources) = makeManager()
        _ = try await manager.importCustomModel(from: CustomModelFixtures.ggufFolder(in: sources, id: "first-gguf"))
        _ = try await manager.importCustomModel(from: CustomModelFixtures.ggufFolder(in: sources, id: "second-gguf"))
        try manager.activateCustomModel(id: "second-gguf", persist: false)
        XCTAssertEqual(registry.activeModel(for: .cleanup)?.id, "second-gguf")
        XCTAssertNil(defaults.string(forKey: CustomModelRegistry.activeKey(for: .cleanup)))
    }

    func testInvalidModelsLeaveNothingBehind() async throws {
        let (manager, registry, sources) = makeManager()
        let folder = try CustomModelFixtures.ggufFolder(in: sources, id: "hybrid", architecture: "qwen35")
        do {
            _ = try await manager.importCustomModel(from: folder)
            XCTFail("A hybrid architecture must be refused")
        } catch let error as CustomModelError {
            guard case .invalid = error else { return XCTFail("Unexpected \(error)") }
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: registry.root.path)) ?? []
        XCTAssertEqual(contents, [])
    }

    func testImportedSherpaModelsCountAsInstalledForTheEngine() async throws {
        let (manager, registry, sources) = makeManager()
        let folder = sources.appendingPathComponent("ctc")
        try CustomModelFixtures.write(CustomModelManifest(
            id: "ctc-model", name: "CTC", engine: .sherpaOnnx, sherpa: .init(type: "nemoCtc", model: "model.onnx")
        ), to: folder)
        try Data("t".utf8).write(to: folder.appendingPathComponent("tokens.txt"))
        try Data("m".utf8).write(to: folder.appendingPathComponent("model.onnx"))
        _ = try await manager.importCustomModel(from: folder)

        let model = try XCTUnwrap(registry.activeModel(for: .sherpaOnnx))
        let spec = try XCTUnwrap(SherpaModelCatalog.customSpec(for: model))
        XCTAssertEqual(SherpaService.modelDirectory(for: spec), model.directory)
        XCTAssertTrue(SherpaService.modelFilesExist(for: spec), "Import writes the completion marker")
    }

    func testSymbolicLinksAreRefusedAndTheirTargetsUntouched() async throws {
        let (manager, registry, sources) = makeManager()
        let folder = sources.appendingPathComponent("linked")
        try CustomModelFixtures.write(CustomModelManifest(
            id: "linked-model", name: "Linked", engine: .sherpaOnnx, sherpa: .init(type: "nemoCtc", model: "model.onnx")
        ), to: folder)
        try Data("t".utf8).write(to: folder.appendingPathComponent("tokens.txt"))
        try Data("m".utf8).write(to: folder.appendingPathComponent("model.onnx"))
        let target = sources.appendingPathComponent("precious.txt")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent(SherpaService.completionMarkerName), withDestinationURL: target
        )
        do {
            _ = try await manager.importCustomModel(from: folder)
            XCTFail("A folder with a symbolic link must be refused")
        } catch let error as CustomModelError {
            guard case .invalid(let problems) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(problems.contains { $0.contains(SherpaService.completionMarkerName) }, "\(problems)")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep me")
        XCTAssertNil(registry.model(id: "linked-model"))
    }

    func testTheInstalledSizeIsMeasuredNotTakenFromTheManifest() async throws {
        let (manager, _, sources) = makeManager()
        let folder = try CustomModelFixtures.whisperFolder(in: sources)
        var manifest = try CustomModelRegistry.readManifest(in: folder)
        manifest.fileSizeBytes = 1
        try CustomModelFixtures.write(manifest, to: folder)
        let installed = try await manager.importCustomModel(from: folder)
        XCTAssertGreaterThan(installed.manifest.fileSizeBytes ?? 0, 1)
    }

    func testAOneOffCLIModelDoesNotOutliveItsRequest() async throws {
        let (manager, registry, sources) = makeManager()
        _ = try await manager.importCustomModel(from: CustomModelFixtures.whisperFolder(in: sources, id: "first-whisper"))
        _ = try await manager.importCustomModel(from: CustomModelFixtures.whisperFolder(in: sources, id: "second-whisper"))
        try manager.activateCustomModel(id: "first-whisper", persist: true)
        let audio = sources.appendingPathComponent("clip.wav")
        try WAVEncoder.pcm16Mono(from: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000).write(to: audio)
        let headless = HeadlessTranscriber(
            modelManager: manager,
            preferences: AppCLIPreferencesReader(defaults: defaults),
            audioLoader: AudioFileLoader(),
            transcriber: MockWhisperService()
        )

        _ = try await headless.transcribe(fileURL: audio, modelOverride: "second-whisper", languageOverride: nil)

        XCTAssertEqual(registry.activeModel(for: .whisperKit)?.id, "first-whisper", "The app's choice is back")
    }

    func testImportedModelsAreNotDownloaded() async {
        let (manager, _, _) = makeManager()
        do {
            try await manager.downloadModel(size: .customWhisperKit) { _ in }
            XCTFail("Nothing to download")
        } catch {
            XCTAssertEqual(error.localizedDescription, ModelManagerError.importedModelNotDownloadable.localizedDescription)
        }
    }
}

// MARK: - Community catalog

final class CommunityModelCatalogTests: XCTestCase {
    private final class FakeServer: @unchecked Sendable {
        var responses: [(Int, Data, [String: String])] = []
        var requests: [URLRequest] = []
        var error: Error?
        let lock = NSLock()

        func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            if let error { throw error }
            let (status, body, headers) = responses.removeFirst()
            let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status, httpVersion: nil, headerFields: headers)
            return (body, response ?? HTTPURLResponse())
        }
    }

    private static let document = Data("""
    {"version":1,"models":[
      {"manifest":{"id":"whisper-small-tamil","name":"Whisper Small Tamil","engine":"whisperKit","languages":["ta"]},
       "downloadURL":"https://huggingface.co/VocaHQ/x/resolve/main/tamil.zip","downloadBytes":250000000},
      {"manifest":{"id":"plain-http","name":"Insecure","engine":"whisperKit"},
       "downloadURL":"http://example.com/model.zip"}
    ]}
    """.utf8)

    private func makeCatalog(_ server: FakeServer) -> CommunityModelCatalog {
        CommunityModelCatalog(
            url: URL(string: "https://example.com/community-models.json") ?? URL(fileURLWithPath: "/"),
            cacheDirectory: CustomModelFixtures.temporaryDirectory(self),
            fetch: { request in try server.fetch(request) }
        )
    }

    func testAFetchedCatalogIsCachedWithItsETagAndInsecureLinksDropped() async {
        let server = FakeServer()
        server.responses = [(200, Self.document, ["ETag": "\"v1\""]), (304, Data(), [:])]
        let catalog = makeCatalog(server)

        let first = await catalog.refresh()
        XCTAssertEqual(first.map(\.id), ["whisper-small-tamil"])
        XCTAssertNil(server.requests[0].value(forHTTPHeaderField: "If-None-Match"))

        let second = await catalog.refresh()
        XCTAssertEqual(server.requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(second.map(\.id), ["whisper-small-tamil"], "304 answers with the cache")
        XCTAssertEqual(catalog.cachedEntries().map(\.id), ["whisper-small-tamil"])
    }

    func testAMissingCatalogMeansNoModels() async {
        let server = FakeServer()
        server.responses = [(200, Self.document, ["ETag": "\"v1\""]), (404, Data(), [:])]
        let catalog = makeCatalog(server)
        _ = await catalog.refresh()
        let entries = await catalog.refresh()
        XCTAssertEqual(entries, [])
        XCTAssertEqual(catalog.cachedEntries(), [])
    }

    func testNetworkFailuresAndBadDocumentsKeepTheCache() async {
        let server = FakeServer()
        server.responses = [(200, Self.document, [:]), (200, Data("not json".utf8), [:])]
        let catalog = makeCatalog(server)
        _ = await catalog.refresh()
        let afterBadDocument = await catalog.refresh()
        XCTAssertEqual(afterBadDocument.map(\.id), ["whisper-small-tamil"])

        server.error = URLError(.notConnectedToInternet)
        let offline = await catalog.refresh()
        XCTAssertEqual(offline.map(\.id), ["whisper-small-tamil"])
    }

    func testANewerDocumentVersionOffersNothing() {
        let future = Data(#"{"version":99,"models":[]}"#.utf8)
        XCTAssertEqual(CommunityModelCatalog.entries(in: future), [])
        XCTAssertNil(CommunityModelCatalog.entries(in: Data("[]".utf8)))
    }
}

// MARK: - Slots and the CLI

final class CustomModelSlotTests: XCTestCase {
    func testSlotsBelongToTheirEnginesAndAreNotInTheStandardCatalog() {
        XCTAssertEqual(ModelSize.customWhisperKit.engine, .whisperKit)
        XCTAssertEqual(ModelSize.customSherpaOnnx.engine, .sherpaOnnx)
        XCTAssertFalse(ModelSize.standardCatalog.contains(.customWhisperKit))
        XCTAssertFalse(ModelSize.standardCatalog.contains(.customSherpaOnnx))
        XCTAssertEqual(CustomModelEngine.whisperKit.modelSlot, .customWhisperKit)
        XCTAssertNil(CustomModelEngine.cleanup.modelSlot)
    }

    func testImportedWhisperNamesMapBackToTheSlot() {
        XCTAssertEqual(WhisperService.modelSize(fromName: "custom-whisper-small-tamil"), .customWhisperKit)
    }

    func testImportedModelsCantBeDownloadedForCleanupEither() {
        XCTAssertEqual(CleanupModelCatalog.placeholderCustomDescriptor.kind, .customGGUF)
    }

    func testListModelsShowsImportedModelsInPlaceOfTheSlots() async throws {
        let suite = "VocaMac-CustomCLI-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let base = CustomModelFixtures.temporaryDirectory(self)
        let registry = CustomModelRegistry(root: base.appendingPathComponent("installed"), defaults: defaults)
        let manager = ModelManager(customModels: registry)
        _ = try await manager.importCustomModel(from: CustomModelFixtures.whisperFolder(in: base))

        let headless = HeadlessTranscriber(
            modelManager: manager,
            preferences: AppCLIPreferencesReader(defaults: defaults),
            audioLoader: AudioFileLoader(),
            transcriber: MockWhisperService()
        )
        let models = headless.listModels().models
        XCTAssertFalse(models.contains { $0.id == ModelSize.customWhisperKit.rawValue })
        let imported = try XCTUnwrap(models.first { $0.id == "whisper-small-tamil" })
        XCTAssertEqual(imported.engine, "whisperkit")
        XCTAssertTrue(imported.downloaded)
        XCTAssertEqual(imported.name, "Whisper Small Tamil")
    }
}
