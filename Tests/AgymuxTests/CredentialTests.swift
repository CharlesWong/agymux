import Testing
import Foundation
@testable import AgymuxCore

@Suite("Credential Tests")
struct CredentialTests {
    @Test("Normalize captured secret strips newline")
    func testNormalizeSecret() {
        let withNewline = Data([0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x0A])
        let normalized = AgyCredential.normalizeCapturedSecret(withNewline)
        #expect(normalized == Data([0x68, 0x65, 0x6C, 0x6C, 0x6F]))
    }

    @Test("Extracts refresh token identity from base64 JSON payload")
    func testRefreshTokenExtraction() {
        let json = """
        {"token":{"access_token":"test_acc_123","refresh_token":"1//0g_test_refresh_token_xyz"}}
        """
        let base64 = Data(json.utf8).base64EncodedString()
        let prefixed = "go-keyring-base64:" + base64 + "\n"
        let data = Data(prefixed.utf8)

        let rt = AgyCredential.refreshTokenIdentity(of: data)
        #expect(rt == "1//0g_test_refresh_token_xyz")
    }

    @Test("Represents same account matches across access token rotations")
    func testRepresentsSameAccount() {
        let json1 = """
        {"token":{"access_token":"token_A","refresh_token":"stable_refresh_123"}}
        """
        let json2 = """
        {"token":{"access_token":"token_B_rotated","refresh_token":"stable_refresh_123"}}
        """
        let d1 = Data(("go-keyring-base64:" + Data(json1.utf8).base64EncodedString()).utf8)
        let d2 = Data(("go-keyring-base64:" + Data(json2.utf8).base64EncodedString()).utf8)

        #expect(AgyCredential.representsSameAccount(d1, d2))

        let json3 = """
        {"token":{"access_token":"token_C","refresh_token":"different_refresh_456"}}
        """
        let d3 = Data(("go-keyring-base64:" + Data(json3.utf8).base64EncodedString()).utf8)
        #expect(!AgyCredential.representsSameAccount(d1, d3))
    }
}
