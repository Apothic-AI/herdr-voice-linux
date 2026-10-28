import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `URLSessionWebSocketTask` completion handlers, spelled the same on both platforms.
///
/// Darwin offers `send(_:completionHandler:)` and `receive(completionHandler:)`; swift-corelibs-foundation ships
/// only the `async` forms. The session code drives sockets from callbacks on purpose (a receive loop that can be
/// cancelled by replacing the socket), so these wrap the Linux async API back into the callback shape instead of
/// rewriting the session as structured concurrency.
enum WebSocketCompat {
    static func send(_ task: URLSessionWebSocketTask, _ message: URLSessionWebSocketTask.Message,
                     completion: @escaping (Error?) -> Void) {
        #if canImport(Darwin)
        task.send(message, completionHandler: completion)
        #else
        Task {
            do {
                try await task.send(message)
                completion(nil)
            } catch {
                completion(error)
            }
        }
        #endif
    }

    static func receive(_ task: URLSessionWebSocketTask,
                        completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        #if canImport(Darwin)
        task.receive(completionHandler: completion)
        #else
        Task {
            do {
                completion(.success(try await task.receive()))
            } catch {
                completion(.failure(error))
            }
        }
        #endif
    }

    /// Starts the task. `resume()` has the same signature on both platforms; this exists so the call sites read
    /// uniformly.
    static func resume(_ task: URLSessionWebSocketTask) { task.resume() }
}
