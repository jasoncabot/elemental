import Foundation

/// The view layer binds to presenters only through this callback — it never imports GitData types.
@MainActor
public protocol PresenterObserving: AnyObject {
    func presenterDidUpdate(_ presenter: AnyObject)
}

/// Shared base: holds a weak observer and notifies on the main actor after state changes.
@MainActor
open class Presenter {
    public weak var observer: PresenterObserving?
    public init() {}
    public func notify() { observer?.presenterDidUpdate(self) }
}
