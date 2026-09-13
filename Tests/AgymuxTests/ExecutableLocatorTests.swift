import Testing
import Foundation
@testable import AgymuxCore

@Suite("ExecutableLocator Tests")
struct ExecutableLocatorTests {
    @Test("Finds system utilities like security or sh")
    func testFindSystemUtilities() {
        let security = ExecutableLocator.find("security")
        #expect(security != nil)
        #expect(security?.hasSuffix("/security") == true)

        let sh = ExecutableLocator.find("sh")
        #expect(sh != nil)
        #expect(sh?.hasSuffix("/sh") == true)
    }

    @Test("Respects extraPaths override")
    func testExtraPathsOverride() {
        let found = ExecutableLocator.find("sh", extraPaths: ["/bin/sh"])
        #expect(found == "/bin/sh")
    }

    @Test("Returns nil for non-existent binary")
    func testNonExistentBinary() {
        let found = ExecutableLocator.find("non_existent_binary_xyz_12345")
        #expect(found == nil)
    }

    @Test("AISW lookup only returns the Switchboard bridge")
    func testAiswLookupRejectsGenericExecutables() {
        let found = ExecutableLocator.find("aisw", extraPaths: ["/bin/sh"])
        #expect(found == nil || URL(fileURLWithPath: found!).lastPathComponent == "aisw-switchboard")
    }
}
