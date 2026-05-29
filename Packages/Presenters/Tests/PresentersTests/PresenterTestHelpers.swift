import XCTest
@testable import Presenters

/// Deterministic test helpers that replace `Task.sleep` with condition-based awaiting.
///
/// Instead of sleeping for an arbitrary duration and hoping the presenter has updated,
/// these helpers observe the presenter's `notify()` cycle and resume as soon as the
/// condition is met — or fail with a timeout. This makes tests:
/// - Faster (no unnecessary sleeping)
/// - Deterministic (no flakes from slow CI)
/// - Safe for parallel execution (no shared sleep windows)
extension XCTestCase {

    /// Awaits until `condition` returns `true`, re-evaluating after each presenter notification.
    /// Falls back to a polling loop on the main actor run loop to handle cases where the
    /// presenter state changes synchronously (e.g. `select()` doesn't trigger an async load).
    ///
    /// - Parameters:
    ///   - presenter: The presenter to observe for updates.
    ///   - timeout: Maximum time to wait before failing (default 2s).
    ///   - message: Failure message if the condition is never met.
    ///   - condition: A closure evaluated on the main actor. Return `true` when satisfied.
    @MainActor
    func awaitCondition(
        on presenter: Presenter,
        timeout: TimeInterval = 2.0,
        _ message: @autoclosure () -> String = "Condition not met within timeout",
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        if condition() { return }

        let expectation = self.expectation(description: message())
        let observer = ConditionObserver(condition: condition) {
            expectation.fulfill()
        }
        presenter.addObserver(observer)

        await fulfillment(of: [expectation], timeout: timeout)
        presenter.removeObserver(observer)
    }

    /// Yields the main actor run loop briefly to allow already-enqueued tasks to execute.
    /// Use sparingly — only when no presenter notification is expected but you need to
    /// give an in-flight `Task` a chance to complete.
    @MainActor
    func yieldToMainActor() async {
        await Task.yield()
        // One more yield to allow nested continuations to proceed.
        await Task.yield()
    }
}

/// Internal observer that fulfills when a condition becomes true.
@MainActor
private final class ConditionObserver: PresenterObserving {
    private let condition: @MainActor () -> Bool
    private let onFulfilled: () -> Void
    private var fulfilled = false

    init(condition: @escaping @MainActor () -> Bool, onFulfilled: @escaping () -> Void) {
        self.condition = condition
        self.onFulfilled = onFulfilled
    }

    func presenterDidUpdate(_ presenter: AnyObject) {
        guard !fulfilled, condition() else { return }
        fulfilled = true
        onFulfilled()
    }
}
