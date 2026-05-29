import Foundation

/// The state of an asynchronously-loaded value.
///
/// Replaces the `(value?, isLoading: Bool, error: Error?)` triad presenters used to carry as
/// three separate fields — a shape that can express contradictions (loading *and* failed *and*
/// loaded at once). As one enum, the state transitions through a single assignment and the
/// impossible combinations simply don't exist.
public enum Loadable<Value> {
    case idle               // nothing requested yet (or explicitly cleared)
    case loading            // a load is in flight
    case loaded(Value)      // the value is available
    case failed(Error)      // the last load failed

    /// The loaded value, if the state is `.loaded`.
    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// Whether a load is currently in flight.
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The failure, if the last load ended in `.failed`.
    public var error: Error? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

// Public types don't get implicit Sendable synthesis. `any Error` is itself Sendable, so this
// holds whenever the loaded value is — letting `Sendable` carriers (e.g. SidebarPresenter.RepoItem)
// store a Loadable without tripping concurrency checking.
extension Loadable: Sendable where Value: Sendable {}
