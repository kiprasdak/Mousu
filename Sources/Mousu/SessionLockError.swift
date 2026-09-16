import Foundation

enum SessionLockError: Error, LocalizedError {
    case operationFailed(Int32)

    static func isContention(_ code: Int32) -> Bool { code == EWOULDBLOCK || code == EAGAIN }

    var errorDescription: String? {
        switch self {
        case .operationFailed(let code):
            "Mousü could not open its session lock: " + String(cString: strerror(code))
        }
    }
}
