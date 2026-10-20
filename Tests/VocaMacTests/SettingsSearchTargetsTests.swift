// SettingsSearchTargetsTests.swift
// VocaMac Tests
//
// Every Settings search result has to land on a control: its destination
// page must declare the entry's id with `.settingsTarget(_:aliases:)`. The
// ids are read from the Calm view sources, so removing a target from a
// view (or moving a control to another page) fails here instead of
// leaving a search result that scrolls nowhere.

import XCTest
@testable import VocaMac

final class SettingsSearchTargetsTests: XCTestCase {

    /// The page each view that declares targets is drawn on. A view missing
    /// from this table fails `testEveryViewWithTargetsIsOnAPage`.
    private static let pageOfView: [String: CalmDestination] = [
        "CalmHomePage": .main(.home),
        "CalmInsightsPage": .main(.insights),
        "CalmDictionaryPage": .main(.dictionary),
        "CalmSnippetsPage": .main(.snippets),
        "CalmStylesPage": .main(.styles),
        "CalmStylesToneGroup": .main(.styles),
        "CalmStylesTryItGroup": .main(.styles),
        "CalmStylesTypedTextGroup": .main(.styles),
        "CalmCommandsPage": .main(.commands),
        "CalmGeneralSettings": .settings(.general),
        "CalmLanguagesSettings": .settings(.languages),
        "CalmSystemSettings": .settings(.system),
        "CalmSpeechModelsTab": .settings(.models),
        "CalmWritingModelsTab": .settings(.models),
        "CalmAllSpeechModels": .settings(.allModels),
        "CalmModelsOnThisMac": .settings(.models),
        "CalmCleanupSettings": .settings(.cleanup),
        "CalmPrivacySettings": .settings(.privacy),
        "CalmAdvancedSettings": .settings(.advanced),
        "CalmGatewaySettings": .settings(.gateway),
        "CalmAboutSettings": .settings(.about),
    ]

    /// Every `.settingsTarget` in the Calm views: the view type it sits in
    /// and the ids (main id and aliases) it declares.
    private static func declaredTargets() throws -> [(view: String, ids: [String])] {
        let calm = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VocaMac/Views/Calm")
        let declaration = try NSRegularExpression(
            pattern: #"^(?:private |fileprivate )?(?:final )?(?:struct|class|enum|extension) (\w+)"#,
            options: .anchorsMatchLines
        )
        let target = try NSRegularExpression(
            pattern: #"\.settingsTarget\(\s*"([^"]+)"(?:\s*,\s*aliases:\s*([^)]*))?\)"#
        )
        let literal = try NSRegularExpression(pattern: #""([^"]+)""#)

        var found: [(String, [String])] = []
        let files = FileManager.default.enumerator(at: calm, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let text = source as NSString
            let all = NSRange(location: 0, length: text.length)
            let types = declaration.matches(in: source, range: all).map {
                (location: $0.range.location, name: text.substring(with: $0.range(at: 1)))
            }
            for match in target.matches(in: source, range: all) {
                let owner = types.last { $0.location < match.range.location }?.name ?? file.lastPathComponent
                var ids = [text.substring(with: match.range(at: 1))]
                let aliases = match.range(at: 2)
                if aliases.location != NSNotFound {
                    let list = text.substring(with: aliases)
                    ids += literal.matches(in: list, range: NSRange(location: 0, length: (list as NSString).length))
                        .map { (list as NSString).substring(with: $0.range(at: 1)) }
                }
                found.append((owner, ids))
            }
        }
        return found
    }

    func testTheScanFindsTheViews() throws {
        // Guards the scan itself: a broken path or pattern would find nothing
        // and let every other test here pass.
        let targets = try Self.declaredTargets()
        XCTAssertGreaterThan(targets.count, 50)
        XCTAssertTrue(targets.contains { $0.view == "CalmGeneralSettings" && $0.ids.contains("hotkey") })
    }

    func testEveryViewWithTargetsIsOnAPage() throws {
        for target in try Self.declaredTargets() {
            XCTAssertNotNil(Self.pageOfView[target.view], "\(target.view) declares \(target.ids) but isn't mapped to a page")
        }
    }

    func testEverySearchEntryLandsOnAControlOfItsPage() throws {
        var idsByPage: [CalmDestination: Set<String>] = [:]
        for target in try Self.declaredTargets() {
            guard let page = Self.pageOfView[target.view] else { continue }
            idsByPage[page, default: []].formUnion(target.ids)
        }
        for entry in SettingsSearchIndex.entries {
            let destination = CalmNavigation.destination(for: entry)
            XCTAssertTrue(
                idsByPage[destination]?.contains(entry.id) == true,
                "“\(entry.title)” (\(entry.id)) opens \(destination.title), which has no .settingsTarget(\"\(entry.id)\")"
            )
        }
    }

    func testWritingAIResultsAreOnTheWritingAITab() throws {
        let writingTab = try Self.declaredTargets()
            .filter { $0.view == "CalmWritingModelsTab" }
            .reduce(into: Set<String>()) { $0.formUnion($1.ids) }
        for id in CalmNavigation.writingAIEntryIDs {
            XCTAssertTrue(writingTab.contains(id), "\(id) opens Writing AI, which doesn't declare it")
        }
    }
}
