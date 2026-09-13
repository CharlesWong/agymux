import Foundation
import Testing
@testable import AgymuxCore

struct SessionSupervisorTests {
    @Test func rewritesArgumentsWithExplicitConversationSeparateValue() {
        let original = ["--conversation", "old-uuid-1", "-p", "hello world"]
        let rewritten = SessionSupervisor.rewriteArgumentsForResume(arguments: original, conversationId: "new-uuid-2")
        #expect(rewritten == ["--conversation", "new-uuid-2", "-p", "hello world"])
    }

    @Test func rewritesArgumentsWithExplicitConversationInlineValue() {
        let original = ["--conversation=old-uuid-1", "-p", "hello world"]
        let rewritten = SessionSupervisor.rewriteArgumentsForResume(arguments: original, conversationId: "new-uuid-2")
        #expect(rewritten == ["--conversation", "new-uuid-2", "-p", "hello world"])
    }

    @Test func rewritesArgumentsReplacingContinueFlags() {
        let original = ["-c", "--model", "gemini-3.8-flash-high", "-p", "hello"]
        let rewritten = SessionSupervisor.rewriteArgumentsForResume(arguments: original, conversationId: "new-uuid-3")
        #expect(rewritten == ["--conversation", "new-uuid-3", "--model", "gemini-3.8-flash-high", "-p", "hello"])

        let originalLong = ["--continue", "-p", "hello"]
        let rewrittenLong = SessionSupervisor.rewriteArgumentsForResume(arguments: originalLong, conversationId: "new-uuid-3")
        #expect(rewrittenLong == ["--conversation", "new-uuid-3", "-p", "hello"])
    }

    @Test func rewritesArgumentsWhenConversationIdIsNil() {
        let originalWithoutContinue = ["-p", "hello"]
        let rewritten = SessionSupervisor.rewriteArgumentsForResume(arguments: originalWithoutContinue, conversationId: nil)
        #expect(rewritten == ["-c", "-p", "hello"])

        let originalWithContinue = ["-c", "-p", "hello"]
        let rewritten2 = SessionSupervisor.rewriteArgumentsForResume(arguments: originalWithContinue, conversationId: nil)
        #expect(rewritten2 == ["-c", "-p", "hello"])
    }
}
