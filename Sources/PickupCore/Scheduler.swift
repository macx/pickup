import Foundation

/// A cancellable delayed action.
@MainActor
public protocol ScheduledTask: AnyObject {
    func cancel()
}

/// Clock and timer source for the core. Injected so state machines run deterministically in tests.
@MainActor
public protocol Scheduler: AnyObject {
    var now: Date { get }
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask
}

/// Production scheduler: wall clock and the main dispatch queue.
@MainActor
public final class MainQueueScheduler: Scheduler {
    public init() {}

    public var now: Date { Date() }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let task = MainQueueTask()
        // The closure keeps the task alive until it ran, so callers may ignore the returned task.
        // Clearing `item` afterwards breaks the task -> item -> closure -> task cycle.
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard !task.isCancelled else { return }
                task.item = nil
                action()
            }
        }
        task.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return task
    }
}

@MainActor
private final class MainQueueTask: ScheduledTask {
    var item: DispatchWorkItem?
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
        item?.cancel()
        item = nil
    }
}
