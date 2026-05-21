import Foundation
import Testing

// MARK: - Repo-root helper
//
// Mirrors the helper in SeshctlCoreTests/FirstLaunchInstallerTests so we can
// locate `Resources/Info.plist` from a known anchor regardless of where the
// test process's CWD lands. Walks up from this source file until it finds
// `Package.swift`.

private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #file)
    while url.path != "/" {
        url = url.deletingLastPathComponent()
        let candidate = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return url
        }
    }
    fatalError("could not find Package.swift walking up from \(#file)")
}

private func loadInfoPlist() throws -> [String: Any] {
    let url = repoRoot().appendingPathComponent("Resources/Info.plist")
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(
        from: data, options: [], format: nil
    )
    guard let dict = plist as? [String: Any] else {
        fatalError("Info.plist did not deserialize to a dictionary")
    }
    return dict
}

// MARK: - Sparkle key tests
//
// Catches accidental regression where a future Info.plist edit strips one of
// Sparkle's required configuration keys. Sparkle does NOT throw a loud error
// if `SUFeedURL` / `SUPublicEDKey` are missing — it just silently disables
// the update path. This guards against that silent failure mode.

@Suite("Info.plist Sparkle keys")
struct InfoPlistSparkleKeysTests {

    @Test("SUFeedURL points at the GitHub Pages appcast URL")
    func testSUFeedURL() throws {
        let plist = try loadInfoPlist()
        let value = try #require(plist["SUFeedURL"] as? String)
        #expect(value == "https://julo15.github.io/seshctl/appcast.xml")
    }

    @Test("SUPublicEDKey decodes to exactly 32 bytes (ed25519 public key)")
    func testSUPublicEDKey() throws {
        let plist = try loadInfoPlist()
        let value = try #require(plist["SUPublicEDKey"] as? String)
        #expect(!value.isEmpty, "SUPublicEDKey must not be empty")
        let decoded = try #require(Data(base64Encoded: value), "SUPublicEDKey must be valid base64")
        #expect(decoded.count == 32, "ed25519 public keys are exactly 32 bytes; got \(decoded.count)")
    }

    @Test("SUEnableAutomaticChecks is true")
    func testSUEnableAutomaticChecks() throws {
        let plist = try loadInfoPlist()
        // PropertyListSerialization parses `<true/>` to NSNumber-backed Bool.
        let value = try #require(plist["SUEnableAutomaticChecks"] as? Bool)
        #expect(value == true, "Sparkle automatic checks must stay enabled — see plan §Key Decisions")
    }
}
