import Foundation
import Testing
@testable import YTDLPGUI_iOS

@Suite("JavaScript challenge runner", .timeLimit(.minutes(1)))
struct JavaScriptChallengeRunnerTests {

    /// Slots of its own for each test, so scripts other tests abandon (tests run in parallel)
    /// never hold this one up.
    private let runner = JavaScriptChallengeRunner(slots: JavaScriptEvaluationSlots(capacity: 16))

    // MARK: - Console

    @Test("log and info are stdout; warn, error and debug are stderr")
    func consoleCapture() async throws {
        let output = try await runner.run("""
            console.log('a', 1, [1, 2], null, undefined);
            console.info('b');
            console.warn('w');
            console.error('e');
            console.debug('d');
            console.log();
            """)
        #expect(output.standardOutput == ["a 1 1,2 null undefined", "b", ""])
        #expect(output.stdout == "a 1 1,2 null undefined\nb\n")
        #expect(output.standardError == ["w", "e", "d"])
    }

    @Test("A script that logs nothing has empty stdout")
    func silentScript() async throws {
        let output = try await runner.run("var x = 1 + 1;")
        #expect(output == JavaScriptOutput())
        #expect(output.stdout.isEmpty)
    }

    @Test("Each run starts from a clean global scope")
    func freshContext() async throws {
        _ = try await runner.run("globalThis.leftover = 42; var alsoLeftover = 1;")
        let output = try await runner.run("console.log(typeof leftover, typeof alsoLeftover)")
        #expect(output.stdout == "undefined undefined")
    }

    @Test("Runs can overlap")
    func concurrentRuns() async throws {
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<6 {
                group.addTask { try await runner.run("console.log(\(index) * 2)").stdout }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outputs.sorted() == ["0", "10", "2", "4", "6", "8"])
    }

    // MARK: - Failures

    @Test("An exception is reported with its message and line")
    func exception() async {
        await #expect(throws: JavaScriptRunnerError.exception(message: "TypeError: null is not an object (evaluating 'null.boom')", line: 3)) {
            try await runner.run("var a = 1;\nvar b = 2;\nnull.boom;")
        }
    }

    @Test("A syntax error is reported on its line")
    func syntaxError() async throws {
        do {
            _ = try await runner.run("var ok = 1;\nfunction (")
            Issue.record("A syntax error should throw")
        } catch let error as JavaScriptRunnerError {
            guard case .exception(let message, let line) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(message.hasPrefix("SyntaxError"))
            #expect(line == 2)
            #expect(error.localizedDescription.contains("line 2"))
        }
    }

    @Test("Throwing something that isn't an Error still produces a message")
    func thrownString() async {
        await #expect(throws: JavaScriptRunnerError.exception(message: "plain text", line: nil)) {
            try await runner.run("throw 'plain text'")
        }
    }

    @Test("A script that overruns its time limit is abandoned")
    func timeout() async {
        let started = ContinuousClock.now
        // Bounded, so the abandoned thread ends by itself shortly after the test.
        await #expect(throws: JavaScriptRunnerError.timedOut(seconds: 1)) {
            try await runner.run("const end = Date.now() + 3000; while (Date.now() < end) {}", timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("Cancelling the calling task returns promptly")
    func cancellation() async throws {
        let task = Task { try await runner.run("const end = Date.now() + 3000; while (Date.now() < end) {}") }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: JavaScriptRunnerError.cancelled) {
            try await task.value
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("Abandoned scripts hold their slot until they end; a run beyond the limit waits, then gives up as busy")
    func evaluationLimit() async throws {
        let slots = JavaScriptEvaluationSlots(capacity: 2)
        let runner = JavaScriptChallengeRunner(slots: slots)
        let slowScript = "const end = Date.now() + 1500; while (Date.now() < end) {}"

        // Two runs time out at once, leaving their scripts running for a while.
        for _ in 0..<2 {
            await #expect(throws: JavaScriptRunnerError.timedOut(seconds: 1)) {
                try await runner.run(slowScript, timeout: .milliseconds(100))
            }
        }
        #expect(slots.running == 2)

        // A third finds no free slot before its own time limit.
        let started = ContinuousClock.now
        await #expect(throws: JavaScriptRunnerError.busy) {
            try await runner.run("console.log(1)", timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - started < .seconds(1))

        // With a longer limit it waits for an abandoned script to end, then runs.
        let output = try await runner.run("console.log(2)", timeout: .seconds(10))
        #expect(output.stdout == "2")

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while slots.running > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(slots.running == 0)
    }

    @Test("A run cancelled while waiting for a slot stops waiting")
    func cancelledWhileWaiting() async throws {
        let slots = JavaScriptEvaluationSlots(capacity: 1)
        let runner = JavaScriptChallengeRunner(slots: slots)
        await #expect(throws: JavaScriptRunnerError.timedOut(seconds: 1)) {
            try await runner.run("const end = Date.now() + 1500; while (Date.now() < end) {}", timeout: .milliseconds(100))
        }
        let waiting = Task { try await runner.run("console.log(1)", timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        waiting.cancel()
        await #expect(throws: JavaScriptRunnerError.cancelled) {
            try await waiting.value
        }
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    // MARK: - The real solver

    /// The solver scripts from yt-dlp-ejs: the copy bundled in the app, or the vendored one when
    /// the tests run outside it.
    private static func solverScript(_ name: String) throws -> String {
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "app_packages/yt_dlp_ejs/yt/solver/\(name)"),
            repository.appending(path: "Vendor/python-packages/yt_dlp_ejs/yt/solver/\(name)"),
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
    }

    /// What yt-dlp's `EJSBaseJCP._construct_stdin` sends, up to the final call.
    private static func solverPrelude() throws -> String {
        "\(try solverScript("lib.min.js"))\nObject.assign(globalThis, lib);\n\(try solverScript("core.min.js"))\n"
    }

    @Test("yt-dlp-ejs's library and core load, and define jsc")
    func solverLoads() async throws {
        let output = try await runner.run(try Self.solverPrelude() + "console.log(typeof jsc); console.log(typeof meriyah, typeof astring);")
        #expect(output.standardOutput == ["function", "object object"])
    }

    @Test("A player without challenge functions comes back as JSON errors, not a crash")
    func solverRejectsFakePlayer() async throws {
        // Shaped like YouTube's player, `var _yt_player={};(function(g){…})(_yt_player);`,
        // which the solver checks before it looks for the challenge functions.
        let player = #"var _yt_player={};(function(g){var window=this;var notAChallenge=function(a){return a.split('').reverse().join('')};})(_yt_player);"#
        let request: [String: Any] = [
            "type": "player",
            "player": player,
            "requests": [["type": "n", "challenges": ["abcdef"]], ["type": "sig", "challenges": ["xyz"]]],
            "output_preprocessed": true,
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let output = try await runner.run(try Self.solverPrelude() + "console.log(JSON.stringify(jsc(\(json))));")

        let answer = try #require(try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        #expect(answer["type"] as? String == "result")
        let responses = try #require(answer["responses"] as? [[String: Any]])
        #expect(responses.count == 2)
        #expect(responses.allSatisfy { $0["type"] as? String == "error" })
        #expect(answer["preprocessed_player"] is String)
    }

    @Test("A player of the wrong shape makes the solver throw, which surfaces as an error")
    func solverRejectsMalformedPlayer() async throws {
        let prelude = try Self.solverPrelude()
        await #expect(throws: JavaScriptRunnerError.exception(message: "unexpected structure", line: nil)) {
            try await runner.run(prelude + "console.log(JSON.stringify(jsc({type: 'player', player: 'var x = 1;', requests: [], output_preprocessed: true})));")
        }
    }
}
