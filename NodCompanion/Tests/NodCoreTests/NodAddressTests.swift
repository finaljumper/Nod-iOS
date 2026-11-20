import XCTest
@testable import NodCore

final class NodAddressTests: XCTestCase {
    private func url(_ text: String) -> String? {
        try? NodAddress.parse(text).get().absoluteString
    }

    func testAnAddressWithoutASchemeIsTakenAsHTTPS() {
        XCTAssertEqual(url("nod.example.com"), "https://nod.example.com")
        XCTAssertEqual(url("  nod.example.com:8443 \n"), "https://nod.example.com:8443")
    }

    func testOnlyHTTPSIsAccepted() {
        XCTAssertEqual(url("HTTPS://Nod.Example.com/"), "https://nod.example.com")
        XCTAssertEqual(NodAddress.parse("http://192.168.1.20:5678"), .failure(.notSecure("http")))
        XCTAssertEqual(NodAddress.parse("ftp://nod.example.com"), .failure(.notSecure("ftp")))
    }

    func testOnlyTheOriginIsKept() {
        // Nod answers at its public origin; a path, query, fragment or credentials are not part of it.
        XCTAssertEqual(url("https://me:secret@nod.example.com/settings?key=abc#top"), "https://nod.example.com")
        XCTAssertEqual(url("https://nod.example.com:443/"), "https://nod.example.com")
    }

    func testWhatIsNotAnAddressIsRefused() {
        XCTAssertEqual(NodAddress.parse("   "), .failure(.empty))
        XCTAssertEqual(NodAddress.parse("my mac mini"), .failure(.notAnAddress))
        XCTAssertEqual(NodAddress.parse("https://"), .failure(.notAnAddress))
    }
}
