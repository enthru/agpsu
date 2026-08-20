import Foundation

/// Something the supply did that is worth interrupting somebody for.
///
/// The event list already records everything; this is the much shorter list of
/// things worth saying out loud to a person who is not looking at the window.
/// A supply left powering a board overnight is exactly the situation where
/// nobody is: the whole point of leaving it running is not to sit with it.
public struct PSUAlert: Equatable, Sendable {

    public enum Kind: String, CaseIterable, Sendable, Codable {
        /// Over-voltage, over-current, over-temperature or a sense fault — the
        /// supply has shut its own output down and is waiting to be told it may
        /// try again.
        case protectionTripped
        /// The output fell out of constant voltage into constant current: the
        /// load is now taking everything the limit allows. On a bench that is
        /// usually the first sign that something under test is not well.
        case wentToConstantCurrent
        /// The supply stopped answering, or the port went away under it.
        case connectionLost

        public var title: String {
            switch self {
            case .protectionTripped: return "Protection tripped"
            case .wentToConstantCurrent: return "Output went to constant current"
            case .connectionLost: return "Connection lost"
            }
        }

        /// What the Settings checkbox says, and why anyone would want it.
        public var explanation: String {
            switch self {
            case .protectionTripped:
                return "Over-voltage, over-current, over-temperature or a sense fault shut the output down"
            case .wentToConstantCurrent:
                return "The load began taking the whole current limit — usually the first sign of trouble"
            case .connectionLost:
                return "The supply stopped answering, ending the session"
            }
        }
    }

    public let kind: Kind
    public let title: String
    public let body: String

    public init(kind: Kind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Whoever turns an alert into something a person notices.
///
/// The controller does not know what that is. On the Mac it is a notification
/// banner, which needs a bundle to exist and permission to have been granted,
/// and neither is true in a test process — hence a protocol rather than a call
/// straight into `UNUserNotificationCenter`.
@MainActor
public protocol AlertPresenter: AnyObject {
    /// Which kinds the presenter wants at all. Asked before each alert is built,
    /// so switching a kind off in Settings takes effect immediately.
    func wantsAlert(of kind: PSUAlert.Kind) -> Bool
    func present(_ alert: PSUAlert)
}
