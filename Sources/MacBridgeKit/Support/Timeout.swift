//
//  Timeout.swift
//  MacBridgeKit · MacBridge
//
//  Waits for work that may never finish, up to a limit, without being stuck on it.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Waits for work that may never finish, up to a limit, without being stuck on it.
///
/// A task group can't do this: leaving a group waits for every child, so an
/// operation that never returns, such as a permission request whose prompt can't
/// appear, would hold the caller forever anyway. Here the operation runs in a task
/// of its own that the caller stops waiting for; it isn't cancelled (EventKit's
/// requests can't be) and finishes, or not, on its own.
enum Timeout {

    /// The operation's result, or nil when `seconds` pass first.
    ///
    /// Throws what the operation throws, or `CancellationError` when the calling
    /// task is cancelled while waiting.
    static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        let gate = ResumeOnce<T?>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.set(continuation)
                let timer = Task {
                    // Cancelled once the operation answers; the resume after it is
                    // then a no-op, since the gate has already been used.
                    try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                    gate.resume(with: .success(nil))
                }
                Task {
                    defer { timer.cancel() }
                    do {
                        gate.resume(with: .success(try await operation()))
                    } catch {
                        gate.resume(with: .failure(error))
                    }
                }
            }
        } onCancel: {
            gate.resume(with: .failure(CancellationError()))
        }
    }
}

/// A continuation that only the first of several racing outcomes resumes.
///
/// An outcome can arrive before the continuation does (cancellation is reported
/// at once if the task was already cancelled), so it is kept and delivered on
/// ``set(_:)`` rather than lost, which would leave the caller waiting.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var used = false

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with outcome: Result<T, Error>) {
        lock.lock()
        guard !used else { lock.unlock(); return }
        used = true
        guard let continuation else {
            early = outcome
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: outcome)
    }
}
