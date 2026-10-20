import Foundation

public enum Delivery: String {
    /// The focused field's text was read before and after and now contains the text.
    case confirmed
    /// The keys were sent but the target does not expose its text, so arrival cannot be checked.
    case unconfirmed
}

public struct InsertOutcome: Equatable {
    public var method: InsertMethod
    public var delivery: Delivery
    public init(method: InsertMethod, delivery: Delivery) { self.method = method; self.delivery = delivery }
}

public enum DeliveryEvidence: Equatable {
    case confirmed
    case unconfirmed
    case notDelivered
}

/// Decides what the before and after text of the focused field proves. nil means unreadable.
public func judgeDelivery(before: String?, after: String?, text: String) -> DeliveryEvidence {
    guard let before = before, let after = after else { return .unconfirmed }
    if after == before { return .notDelivered }
    // Something changed: it only counts as proof if our text is in there (apps may rewrite it).
    return after.contains(text) ? .confirmed : .unconfirmed
}

/// The order of attempts and what each outcome means, with the OS pieces injected so it can be tested.
public struct InsertionFlow {
    /// Text of the focused field, nil if the focused element does not expose it.
    public var readFocusedText: () -> String?
    /// Waits for the field to show `text` (polling), returning its last reading.
    public var readAfter: (_ text: String, _ before: String?) -> String?
    public var paste: (String) throws -> Void
    public var type: (String) throws -> Void

    public init(readFocusedText: @escaping () -> String?, readAfter: @escaping (String, String?) -> String?,
                paste: @escaping (String) throws -> Void, type: @escaping (String) throws -> Void) {
        self.readFocusedText = readFocusedText; self.readAfter = readAfter; self.paste = paste; self.type = type
    }

    /// Never returns an outcome without having sent the keys, and throws `notDelivered` when it
    /// could read the field and the text did not appear. With no method given it pastes, and if the
    /// paste provably did not arrive it types the text instead.
    public func run(_ text: String, method: InsertMethod?) throws -> InsertOutcome {
        func attempt(_ m: InsertMethod) throws -> DeliveryEvidence {
            let before = readFocusedText()
            if m == .paste { try paste(text) } else { try type(text) }
            return judgeDelivery(before: before, after: readAfter(text, before), text: text)
        }
        func outcome(_ m: InsertMethod, _ e: DeliveryEvidence) throws -> InsertOutcome {
            switch e {
            case .confirmed: return InsertOutcome(method: m, delivery: .confirmed)
            case .unconfirmed: return InsertOutcome(method: m, delivery: .unconfirmed)
            case .notDelivered: throw InsertError.notDelivered
            }
        }
        switch method {
        case .some(let m): return try outcome(m, try attempt(m))
        case .none:
            var pasted: DeliveryEvidence
            do { pasted = try attempt(.paste) } catch InsertError.accessibilityNotGranted { throw InsertError.accessibilityNotGranted }
            catch { pasted = .notDelivered }     // could not even set the paste up: type instead
            if pasted != .notDelivered { return try outcome(.paste, pasted) }
            return try outcome(.type, try attempt(.type))
        }
    }
}
