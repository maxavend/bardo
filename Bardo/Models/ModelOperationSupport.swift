import Foundation

/// Fans one operation's progress out to every caller waiting on it. Callers can join
/// while the operation runs; progress callbacks arrive on arbitrary threads.
final class ProgressFanOut<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (Value) -> Void] = [:]
    private var latest: Value?

    @discardableResult
    func add(_ observer: @escaping @Sendable (Value) -> Void) -> UUID {
        let id = UUID()
        let current = lock.bardoWithLock {
            observers[id] = observer
            return latest
        }
        if let current { observer(current) }
        return id
    }

    func remove(_ id: UUID) {
        lock.bardoWithLock { _ = observers.removeValue(forKey: id) }
    }

    func send(_ value: Value) {
        let snapshot = lock.bardoWithLock {
            latest = value
            return Array(observers.values)
        }
        snapshot.forEach { $0(value) }
    }
}

/// Waits for a task's result but returns as soon as the waiting task is cancelled,
/// even when the underlying work cannot stop immediately.
enum CancellableAwait {
    static func value<T: Sendable>(of task: Task<T, Error>, cancelUnderlyingTask: Bool = true) async throws -> T {
        let box = ResultBox<T>()
        Task {
            do {
                box.finish(.success(try await task.value))
            } catch {
                box.finish(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await box.wait()
        } onCancel: {
            if cancelUnderlyingTask { task.cancel() }
            box.finish(.failure(CancellationError()))
        }
    }

    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var continuation: CheckedContinuation<T, Error>?

        func wait() async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<T, Error>? = lock.bardoWithLock {
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }

        func finish(_ value: Result<T, Error>) {
            let waiting: CheckedContinuation<T, Error>? = lock.bardoWithLock {
                guard result == nil else { return nil }
                result = value
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: value)
        }
    }
}

enum ModelOperationError: Error, LocalizedError, Equatable, Sendable {
    case inUse

    var errorDescription: String? {
        switch self {
        case .inUse:
            return "This model is being used right now. Try again when the current transcription or speaker identification finishes."
        }
    }
}
