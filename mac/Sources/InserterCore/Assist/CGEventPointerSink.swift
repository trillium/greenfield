import Foundation
import CoreGraphics
import KitAssist

/// The one sink that moves the real cursor, with CGEvent. NOTHING in the tests, the self-test or any script calls it: live pointer
/// injection stays blocked until a supervised test on a scratch Mac or a macOS VM (docs/assist-pointer.md, "Live test").
///
/// What it renders: relative motion (a drag while a button is held), clicks with their count, held buttons, scrolling in pixels, and
/// "release all". Zoom and swipes are ignored and not advertised, and momentum is not synthesized. Whether applications honour the scroll
/// phases, and whether the system flips the direction again for natural scrolling, is unverified until that live test.
public final class CGEventPointerSink: PointerSink {
    public let capabilities: AssistCapabilities = []

    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private var held: Set<PointerButton> = []
    private var scrollRemainder = (x: 0.0, y: 0.0)

    public init() {}

    public func apply(_ events: [PointerEvent]) {
        lock.lock(); defer { lock.unlock() }
        for event in events {
            switch event {
            case let .move(dx, dy): move(dx: dx, dy: dy)
            case let .click(button, count): click(button, count: count)
            case let .button(button, down): setButton(button, down: down)
            case let .scroll(phase, dx, dy, _, _): scroll(phase: phase, dx: dx, dy: dy)
            case .releaseAll: releaseAll()
            case .zoom, .swipe: break
            }
        }
    }

    // MARK: Position

    private var position: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// The cursor stays on a screen: the target is clamped to the union of the active displays.
    private func clamp(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else { return point }
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1), y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    private func move(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        let here = position
        let target = clamp(CGPoint(x: here.x + dx, y: here.y + dy))
        let type: CGEventType
        let button: CGMouseButton
        if held.contains(.left) { (type, button) = (.leftMouseDragged, .left) }
        else if held.contains(.right) { (type, button) = (.rightMouseDragged, .right) }
        else if held.contains(.middle) { (type, button) = (.otherMouseDragged, .center) }
        else { (type, button) = (.mouseMoved, .left) }
        post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button))
    }

    // MARK: Buttons

    private static func types(_ button: PointerButton) -> (down: CGEventType, up: CGEventType, button: CGMouseButton) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    private func click(_ button: PointerButton, count: Int) {
        let kind = Self.types(button)
        let here = position
        for type in [kind.down, kind.up] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: here, mouseButton: kind.button) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(min(max(count, 1), 3)))
            post(event)
        }
    }

    private func setButton(_ button: PointerButton, down: Bool) {
        guard down != held.contains(button) else { return }
        let kind = Self.types(button)
        if down { held.insert(button) } else { held.remove(button) }
        guard let event = CGEvent(mouseEventSource: source, mouseType: down ? kind.down : kind.up, mouseCursorPosition: position, mouseButton: kind.button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        post(event)
    }

    private func releaseAll() {
        for button in held.sorted(by: { $0.rawValue < $1.rawValue }) { setButton(button, down: false) }
        scrollRemainder = (0, 0)
    }

    // MARK: Scroll

    private func scroll(phase: ScrollPhase, dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        if phase == .cancelled || phase == .began { scrollRemainder = (0, 0) }
        let x = dx + scrollRemainder.x, y = dy + scrollRemainder.y
        let wholeX = x.rounded(.towardZero), wholeY = y.rounded(.towardZero)
        scrollRemainder = (x - wholeX, y - wholeY)
        guard wholeX != 0 || wholeY != 0,
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(clamping: Int(wholeY)),
                                  wheel2: Int32(clamping: Int(wholeX)), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        post(event)
    }

    private func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }
}
