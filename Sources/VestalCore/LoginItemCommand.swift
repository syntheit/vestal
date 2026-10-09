import Foundation

// MARK: - vestal login-item
//
// `vestal login-item on|off|status`: whether vestal starts at login. The
// arguments are parsed here (and tested on Linux); the macOS app carries the
// action out with SMAppService (VestalMac/LoginItem.swift).

public enum LoginItemCommand {
    public enum Action: String, Equatable, Sendable {
        case on, off, status
    }

    public struct UsageError: Error, Equatable {
        public let message: String
    }

    public static func parse(_ arguments: [String]) -> Result<Action, UsageError> {
        guard arguments.count == 1, let action = Action(rawValue: arguments[0]) else {
            return .failure(UsageError(message: "'login-item' takes one of: on, off, status"))
        }
        return .success(action)
    }
}
