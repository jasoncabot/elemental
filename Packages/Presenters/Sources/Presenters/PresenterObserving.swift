import Foundation

/// The view layer binds to presenters only through this callback — it never imports GitData types.
@MainActor
public protocol PresenterObserving: AnyObject {
    func presenterDidUpdate(_ presenter: AnyObject)
}

/// Shared base: notifies observers on the main actor after state changes.
///
/// Supports multiple weak observers so a single presenter can drive more than one pane
/// (e.g. the files list and the diff canvas both observe the same commit-detail presenter,
/// keeping file selection and the rendered diff in lockstep).
@MainActor
open class Presenter {
    private var observers: [WeakObserver] = []

    public init() {}

    public func addObserver(_ observer: PresenterObserving) {
        observers.removeAll { $0.value == nil || $0.value === observer }
        observers.append(WeakObserver(observer))
    }

    public func removeObserver(_ observer: PresenterObserving) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    public func notify() {
        observers.removeAll { $0.value == nil }
        for box in observers { box.value?.presenterDidUpdate(self) }
    }

    private final class WeakObserver {
        weak var value: PresenterObserving?
        init(_ value: PresenterObserving) { self.value = value }
    }
}
