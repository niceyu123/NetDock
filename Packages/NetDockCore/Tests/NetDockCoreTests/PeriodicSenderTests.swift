import XCTest
@testable import NetDockCore

@MainActor
final class PeriodicSenderTests: XCTestCase {
    func testFiniteRunSendsImmediatelyAndCompletesExactCount() async throws {
        let sender = PeriodicSender()
        var calls = 0
        try sender.start(interval: 0.1, total: 3) { calls += 1 }
        await sender.waitUntilIdle()
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(sender.sentCount, 3)
        XCTAssertEqual(sender.state, .completed)
        XCTAssertNil(sender.lastError)
    }

    func testPausePreventsFurtherCallsAndResumeSendsOnlyRemainder() async throws {
        let sender = PeriodicSender()
        var calls = 0
        try sender.start(interval: 0.1, total: 3) { calls += 1 }
        try await until { calls == 1 }
        sender.pause()
        await sender.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(sender.state, .paused)
        sender.resume()
        await sender.waitUntilIdle()
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(sender.sentCount, 3)
        XCTAssertEqual(sender.state, .completed)
    }

    func testStopCancelsInfiniteLoopAndResumeDoesNotRestart() async throws {
        let sender = PeriodicSender()
        var calls = 0
        try sender.start(interval: 0.1, total: nil) { calls += 1 }
        try await until { calls == 1 }
        sender.stop()
        await sender.waitUntilIdle()
        sender.resume()
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(sender.sentCount, 1)
        XCTAssertEqual(sender.state, .idle)
    }

    func testReplacementWaitsForSuspendedOperationAndIgnoresItsLateFailure() async throws {
        let sender = PeriodicSender()
        let gate = SuspendedSend()
        var active = 0
        var maximumActive = 0
        var newCalls = 0
        try sender.start(interval: 0.1, total: 3) {
            active += 1; maximumActive = max(maximumActive, active)
            await gate.wait()
            active -= 1
            throw NetDockError(.refused)
        }
        try await until { gate.isWaiting }
        sender.stop()
        try sender.start(interval: 0.1, total: 2) {
            active += 1; maximumActive = max(maximumActive, active)
            newCalls += 1
            active -= 1
        }
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(newCalls, 0)
        XCTAssertEqual(sender.sentCount, 0)
        XCTAssertNil(sender.lastError)
        gate.release()
        await sender.waitUntilIdle()
        XCTAssertEqual(newCalls, 2)
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(sender.sentCount, 2)
        XCTAssertEqual(sender.state, .completed)
        XCTAssertNil(sender.lastError)
    }

    func testPauseAndResumeWaitForSuspendedSendAndCountItsSuccessfulCompletion() async throws {
        let sender = PeriodicSender()
        let gate = SuspendedSend()
        var calls = 0
        try sender.start(interval: 0.1, total: 2) {
            calls += 1
            if calls == 1 { await gate.wait() }
        }
        try await until { gate.isWaiting }
        sender.pause()
        sender.resume()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(calls, 1)
        gate.release()
        await sender.waitUntilIdle()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(sender.sentCount, 2)
        XCTAssertEqual(sender.state, .completed)
    }

    func testRepeatedStartCancelsSupersededLoopsBeforeTheyCanSend() async throws {
        let sender = PeriodicSender()
        var obsoleteCalls = 0
        var latestCalls = 0
        for _ in 0..<10 { try sender.start(interval: 0.1, total: 5) { obsoleteCalls += 1 } }
        try sender.start(interval: 0.1, total: 1) { latestCalls += 1 }
        await sender.waitUntilIdle()
        XCTAssertEqual(obsoleteCalls, 0)
        XCTAssertEqual(latestCalls, 1)
        XCTAssertEqual(sender.sentCount, 1)
    }

    func testReleasingSenderCancelsItsInfiniteLoop() async throws {
        var sender: PeriodicSender? = PeriodicSender()
        weak var releasedSender: PeriodicSender?
        releasedSender = sender
        var calls = 0
        try sender?.start(interval: 0.1, total: nil) { calls += 1 }
        try await until { calls == 1 }
        sender = nil
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertNil(releasedSender)
        XCTAssertEqual(calls, 1)
    }

    func testErrorStopsAutomaticallyAndValidationDoesNotCancelRunningLoop() async throws {
        let sender = PeriodicSender()
        var calls = 0
        try sender.start(interval: 0.1, total: nil) {
            calls += 1
            throw NetDockError(.noPeers)
        }
        await sender.waitUntilIdle()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(sender.state, .idle)
        XCTAssertEqual(sender.sentCount, 0)
        XCTAssertEqual(sender.lastError?.code, .noPeers)
        for interval in [0.099, 0, -1, .infinity, .nan] {
            XCTAssertThrowsError(try sender.start(interval: interval, total: 1) {}) {
                XCTAssertEqual(($0 as? NetDockError)?.code, .invalidInterval)
            }
        }
        for total in [0, -1] {
            XCTAssertThrowsError(try sender.start(interval: 0.1, total: total) {}) {
                XCTAssertEqual(($0 as? NetDockError)?.code, .invalidRepeatCount)
            }
        }
        XCTAssertEqual(sender.lastError?.code, .noPeers)
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for sender operation")
    }
}

@MainActor
private final class SuspendedSend {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
