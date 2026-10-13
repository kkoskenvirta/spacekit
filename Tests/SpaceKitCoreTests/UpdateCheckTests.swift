import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Update check")
struct UpdateCheckTests {
    let key = "cs_live_a1T0lpfMLaJzHZNULK0EMwUWxwF5bq7pUerUaRNZkkBerXOqc24580O9Hx"
    let server = URL(string: "https://spacekit.studio")!

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

    @Test("The appcast carries the purchase key when there is one")
    func appcast() {
        #expect(UpdateCheck.appcastURL(server: server, purchaseKey: nil).absoluteString == "https://spacekit.studio/appcast.xml")
        #expect(
            UpdateCheck.appcastURL(server: server, purchaseKey: key).absoluteString
                == "https://spacekit.studio/appcast.xml?key=\(key)")
        #expect(UpdateCheck.appcastURL(server: server, purchaseKey: "not a key").absoluteString == "https://spacekit.studio/appcast.xml")
    }

    @Test("The download page carries the purchase key when there is one")
    func downloadPage() {
        #expect(UpdateCheck.downloadPageURL(server: server, purchaseKey: nil).absoluteString == "https://spacekit.studio/update")
        #expect(
            UpdateCheck.downloadPageURL(server: server, purchaseKey: key).absoluteString
                == "https://spacekit.studio/update?session_id=\(key)")
    }
}
