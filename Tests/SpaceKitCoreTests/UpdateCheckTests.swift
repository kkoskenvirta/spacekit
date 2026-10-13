import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Update check")
struct UpdateCheckTests {
    let key = "cs_live_a1T0lpfMLaJzHZNULK0EMwUWxwF5bq7pUerUaRNZkkBerXOqc24580O9Hx"
    let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)

    func release(_ version: String, minimum: String? = "15.0", page: String? = "/update") -> ReleaseInfo {
        ReleaseInfo(version: version, notes: nil, size: 9_400_000, minimumSystemVersion: minimum, downloadPage: page)
    }

    @Test("Versions compare number by number")
    func versionOrder() {
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.1")!)
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(AppVersion("v0.2.0")! == AppVersion("0.2")!)
        #expect(AppVersion("0.2.1")! > AppVersion("0.2")!)
        for bad in ["", "1..2", "1.2.3.4.5", "1.x", "-1", "1.2-beta", "１.２"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    @Test("Only a newer version that runs on this macOS is an update")
    func isUpdate() {
        #expect(UpdateCheck.isUpdate(release("0.2.0"), over: "0.1.0", system: sequoia))
        #expect(!UpdateCheck.isUpdate(release("0.1.0"), over: "0.1.0", system: sequoia))
        #expect(!UpdateCheck.isUpdate(release("0.1.0"), over: "0.2.0", system: sequoia))
        #expect(!UpdateCheck.isUpdate(release("0.3.0", minimum: "16.0"), over: "0.2.0", system: sequoia))
        #expect(UpdateCheck.isUpdate(release("0.3.0", minimum: nil), over: "0.2.0", system: sequoia))
        #expect(!UpdateCheck.isUpdate(release("garbage"), over: "0.2.0", system: sequoia))
        #expect(!UpdateCheck.isUpdate(release("0.3.0"), over: "unknown", system: sequoia))
    }

    @Test("The server's JSON decodes, extra fields and all")
    func decode() throws {
        let json =
            #"{"version":"0.2.0","notes":"Updates","size":9399852,"published_at":"2026-10-13T09:00:00Z","minimum_system_version":"15.0","download_page":"/update"}"#
        let info = try UpdateCheck.decode(Data(json.utf8))
        #expect(
            info == ReleaseInfo(version: "0.2.0", notes: "Updates", size: 9_399_852, minimumSystemVersion: "15.0", downloadPage: "/update"))
    }

    @Test("A purchase key is found in the key itself or in a download page address")
    func purchaseKey() {
        #expect(UpdateCheck.purchaseKey(in: "  \(key)\n") == key)
        #expect(UpdateCheck.purchaseKey(in: "https://spacekit.studio/thanks?session_id=\(key)") == key)
        #expect(UpdateCheck.purchaseKey(in: "spacekit://activate?key=\(key)") == key)
        #expect(UpdateCheck.purchaseKey(in: "https://spacekit.studio/thanks") == nil)
        #expect(UpdateCheck.purchaseKey(in: "cs_live_short") == nil)
        #expect(UpdateCheck.purchaseKey(in: "pi_3abcdefghijklmnop") == nil)
        #expect(UpdateCheck.purchaseKey(in: "cs_live_abc/../../etc") == nil)
    }

    @Test("The download page carries the purchase key when there is one")
    func downloadPage() {
        let server = URL(string: "https://spacekit.studio")!
        #expect(UpdateCheck.feedURL(server: server).absoluteString == "https://spacekit.studio/api/updates/latest")
        #expect(UpdateCheck.downloadPageURL(server: server, purchaseKey: nil).absoluteString == "https://spacekit.studio/update")
        #expect(
            UpdateCheck.downloadPageURL(server: server, release: release("0.2.0"), purchaseKey: key).absoluteString
                == "https://spacekit.studio/update?session_id=\(key)")
        #expect(UpdateCheck.downloadPageURL(server: server, purchaseKey: "not a key").absoluteString == "https://spacekit.studio/update")
    }
}
