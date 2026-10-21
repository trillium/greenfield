import KitHealth

/// What this app logs, in the shared diagnostics log (KitHealth `EventLog`); categories are an open set each app names.
extension EventLog.Category {
    static let app = EventLog.Category("app")
    static let sound = EventLog.Category("sound")
    static let rule = EventLog.Category("rule")
    static let dictation = EventLog.Category("dictation")
    static let send = EventLog.Category("send")
    static let mic = EventLog.Category("mic")
    static let model = EventLog.Category("model")
}
