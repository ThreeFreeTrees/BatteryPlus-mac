// MenuRows.swift — custom row views for the menu.
//
// Layout convention, taken from the system's own menu: text starts 20 pt from the leading edge and
// trailing content ends 14 pt from the trailing edge. The energy row used to break that convention —
// its icon sat at 8 pt — which is what visibly ate the left margin.
//
// The Low Power control is a *switch* on the trailing edge rather than the system's icon+pill row.
// That is a deliberate departure from the replica (asked for explicitly): the label keeps the text
// margin and the switch the trailing margin, so the row reads as a single control. The system's
// icon+pill treatment is preserved in spikes/003-menu-replica if we ever want it back.
//
// Everything custom is still drawn with Core Graphics and still keeps the menu's own conventions:
// hover highlight, click-anywhere target, and an accessibility role so VoiceOver sees a checkbox
// rather than an unlabelled view.

import AppKit

/// The menu's standard text margins, in points.
enum MenuMetrics {
    static let leading: CGFloat = 20
    static let trailing: CGFloat = 14
    static let rowHeight: CGFloat = 28
}

/// "Battery" on the left, the percentage on the right — the menu's first line.
final class HeaderRowView: NSView {
    init(title: String, detail: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leading),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailing),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// "Power Source: Power Adapter", "Charged to 80% Limit" — the secondary lines under the header.
/// A hairline rule above makes the "Charged to … Limit" line read as belonging to the adapter
/// rather than floating on its own.
final class SecondaryRowView: NSView {
    private let label = NSTextField(labelWithString: "")
    init(text: String, separatorAbove: Bool = false) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: separatorAbove ? 24 : 18))
        label.stringValue = text
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leading),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.separatorAbove = separatorAbove
    }
    private var separatorAbove = false
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Updates the line in place. Needed because a chip's set completes while the menu is still open
    /// — nothing rebuilds the menu at that moment, so the row has to change itself.
    func setText(_ text: String) {
        label.stringValue = text
    }

    override func draw(_ dirtyRect: NSRect) {
        guard separatorAbove else { return }
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        let line = NSRect(x: MenuMetrics.leading, y: bounds.maxY - 1, width: bounds.width - MenuMetrics.leading - MenuMetrics.trailing, height: 1)
        line.fill()
    }
}

/// A grey section header ("Energy Mode").
final class SectionHeaderView: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 18))
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leading),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A switch drawn for a menu rather than using NSSwitch: the stock control is sized and coloured for
/// a settings window, not for a menu, and its blue reads as a form control instead of a state.
///
/// Proportions: 34x20 pt track, 16 pt knob, 2 pt inset, knob shadowed so it has depth on the menu's
/// translucent material. Built from CALayers rather than `draw(_:)` — see `setOn(_:animated:)`.
final class ToggleSwitchView: NSView {
    private(set) var isOn: Bool
    private let trackLayer = CALayer()
    private let knobLayer = CALayer()

    /// 0.14 s in normal use. `--slow-toggle` stretches it for measurement: a 140 ms travel cannot be
    /// caught in a screenshot, so the animation is verified by slowing it down and sampling frames.
    private let duration: CFTimeInterval = CommandLine.arguments.contains("--slow-toggle") ? 1.6 : 0.14
    private let inset: CGFloat = 2

    /// Exposed so the row knows how long to wait before dismissing the menu.
    var animationDuration: TimeInterval { duration }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 20))
        wantsLayer = true
        layer?.masksToBounds = false
        trackLayer.cornerCurve = .continuous
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.22
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: 0.5)
        trackLayer.addSublayer(knobLayer)
        layer?.addSublayer(trackLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The row handles clicks (so the whole row is a target); the switch must not swallow them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)          // geometry changes must never animate
        let height = bounds.height
        let diameter = height - inset * 2
        trackLayer.frame = bounds
        trackLayer.cornerRadius = height / 2
        knobLayer.frame = NSRect(x: knobX(for: isOn), y: inset, width: diameter, height: diameter)
        knobLayer.cornerRadius = diameter / 2
        trackLayer.backgroundColor = trackColour(for: isOn)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        trackLayer.backgroundColor = trackColour(for: isOn)
        CATransaction.commit()
    }

    private func knobX(for state: Bool) -> CGFloat {
        let diameter = bounds.height - inset * 2
        let travel = bounds.width - diameter - inset * 2
        return inset + travel * (state ? 1 : 0)
    }

    private func trackColour(for state: Bool) -> CGColor {
        (state ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
    }

    /// Animated with Core Animation, deliberately NOT with `draw(_:)`.
    ///
    /// An open menu is a static surface: its window repaints when an event arrives, not when a view
    /// marks itself dirty. A timer that updates a drawn knob therefore changes nothing on screen —
    /// the knob appears to teleport once the menu finally closes — and neither `displayIfNeeded()`
    /// nor a forced `window.display()` gets past that. Layer animations are composited by the render
    /// server, which keeps running while the app sits in menu tracking, so the travel is visible.
    func setOn(_ value: Bool, animated: Bool) {
        guard value != isOn else { return }
        isOn = value
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(animated ? duration : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        knobLayer.frame.origin.x = knobX(for: value)
        trackLayer.backgroundColor = trackColour(for: value)
        CATransaction.commit()
        CATransaction.flush()      // hand it to the render server while menu tracking still has us
    }
}

/// Keeps a menu row's hover honest while a menu is tracking.
///
/// The problem it solves: a row's highlight used to be set by `mouseEntered` and cleared by `mouseExited`
/// — and the *exit* is exactly the event that goes missing. Sweep the cursor quickly through the menu and
/// rows stay lit long after the pointer has left ("some rows get highlighted, but the cursor is not on the
/// row"), because AppKit only sends the exit if it still believes the pointer was inside the area. Entering
/// a row is reliable; leaving one is not.
///
/// So while a row is hovered, a tracking-mode timer asks the **pointer** where it is — `NSEvent.mouseLocation`
/// is a global position that needs no permissions and no event delivery — and reports the exit itself as soon
/// as the pointer is outside the row's screen frame. Registered for `.common` *and* `.eventTracking`, because
/// a menu's tracking loop drains neither the default mode nor the main queue.
final class RowHoverTracker {
    private weak var row: NSView?
    private var timer: Timer?
    /// Called while the pointer is inside, once per tick — a row with sub-areas (the chips) re-derives them.
    var onTick: (() -> Void)?
    /// Called when the pointer is verified to be outside the row, whether or not `mouseExited` ever arrived.
    var onExit: (() -> Void)?

    init(row: NSView) { self.row = row }

    var isPointerInside: Bool { pointerInRow != nil }

    /// The pointer's position inside the row, or nil when it is outside — the pointer's real position is
    /// the truth here, not the last event the row happened to receive.
    var pointerInRow: NSPoint? {
        guard let row, let window = row.window else { return nil }
        let local = row.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return row.bounds.contains(local) ? local : nil
    }

    func pointerEntered() {
        startWatching()
        onTick?()
    }

    /// Deliberately does not clear anything on its own: `mouseExited` can arrive while the pointer is
    /// still inside the row (a tracking area replaced mid-move is enough), and trusting it would clear a
    /// highlight the user is looking at. The pointer decides.
    func pointerExited() {
        verify()
    }

    private func startWatching() {
        guard timer == nil else { onTick?(); return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.verify() }
        RunLoop.current.add(timer, forMode: .common)
        RunLoop.current.add(timer, forMode: .eventTracking)
        self.timer = timer
    }

    private func verify() {
        if isPointerInside {
            onTick?()                      // still inside: keep watching, keep the highlight
        } else {
            stop()
            if CommandLine.arguments.contains("--hover-log") {
                DemoLog.write("hover exit verified for \(type(of: row ?? NSView()))")
            }
            onExit?()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// A row with a label on the menu's text margin and a switch on its trailing margin.
final class ToggleRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let toggle: ToggleSwitchView
    private var isHovered = false
    var onToggle: ((Bool) -> Void)?

    init(title: String, isOn: Bool, enabled: Bool) {
        toggle = ToggleSwitchView(isOn: isOn)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: MenuMetrics.rowHeight))

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(toggle)
        // Switch FIRST, label after it — asked for explicitly. The switch keeps the menu's text
        // margin so the column still lines up with every other row.
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leading),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 34),
            toggle.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                 constant: -MenuMetrics.trailing),
        ])

        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
        hover.onExit = { [weak self] in self?.setHovered(false) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private lazy var hover = RowHoverTracker(row: self)

    /// Hover is set by `mouseEntered` but cleared by **verifying the pointer's real position**, never by
    /// waiting for `mouseExited` — the exit is the event that goes missing on a fast sweep. See
    /// `RowHoverTracker` for the measurements. (`.inVisibleRect` with `rect: .zero` was tried as the fix
    /// and is not it: inside a popup menu's own view hierarchy that combination stops delivering events
    /// altogether and the hover highlight vanishes entirely. Keep `rect: bounds`.)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
        hover.pointerEntered()
    }
    override func mouseExited(with event: NSEvent) { hover.pointerExited() }
    private func setHovered(_ value: Bool) {
        guard value != isHovered else { return }
        isHovered = value
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        activate()
    }

    /// The whole effect of a click, factored out so the interaction test can drive exactly this code
    /// path (see `--demo-toggle-after`) rather than a synthetic mouse event that a menu popup window
    /// will not accept from a non-active app.
    func activate() {
        let newValue = !toggle.isOn
        toggle.setOn(newValue, animated: true)
        setAccessibilityValue(newValue ? 1 : 0)
        onToggle?(newValue)
        // Dismiss only once the switch has finished travelling — closing immediately (the usual menu
        // behaviour) hid the animation completely, since the menu is gone before the knob moves.
        let travel = toggle.animationDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + travel + 0.1) { [weak self] in
            self?.enclosingMenuItem?.menu?.cancelTracking()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // A neutral highlight, not the accent pill: the switch is already the coloured element and
        // two saturated blues in one row fight each other.
        if isHovered {
            NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.55).setFill()
            let pill = bounds.insetBy(dx: 5, dy: 2)
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Five round chips — 80/85/90/95/100 % — that set the charge limit directly by driving the system's
/// own Charge Limit control (see ChargeLimitSetter). The chip matching the current limit — read from
/// the settings record powerd keeps — is highlighted; hover and click are per-chip.
final class LimitChipRowView: NSView {
    static let values = [80, 85, 90, 95, 100]

    var onSelect: ((Int) -> Void)?
    private var chipRects: [NSRect] = []
    private var currentLimit: Int?
    private let isEnabled: Bool
    private var hoveredChip: Int?

    init(currentLimit: Int?, enabled: Bool) {
        self.currentLimit = currentLimit
        self.isEnabled = enabled
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        hover.onTick = { [weak self] in self?.updateHoveredChipFromPointer() }
        hover.onExit = { [weak self] in
            guard let self else { return }
            self.hoveredChip = nil
            self.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private lazy var hover = RowHoverTracker(row: self)

    /// Moves the highlight after a chip's set has been accepted by the system. The menu is open while
    /// that happens, so this view repaints itself instead of waiting for a rebuild — otherwise the
    /// blue stays on the old value until the menu is reopened.
    func update(currentLimit: Int?) {
        self.currentLimit = currentLimit
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var rects: [NSRect] = []
        let inset: CGFloat = MenuMetrics.leading
        let trailing = MenuMetrics.trailing
        let gap: CGFloat = 5
        let height: CGFloat = 22
        let width = (bounds.width - inset - trailing - gap * CGFloat(Self.values.count - 1))
            / CGFloat(Self.values.count)
        let y = (bounds.height - height) / 2
        var x = inset
        for _ in Self.values {
            rects.append(NSRect(x: x, y: y, width: width, height: height))
            x += width + gap
        }
        chipRects = rects
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hover.pointerEntered()
        updateHoveredChipFromPointer()
    }
    override func mouseExited(with event: NSEvent) { hover.pointerExited() }

    /// The hovered chip is derived from where the pointer actually *is* (see `RowHoverTracker`), so a
    /// missed exit cannot leave a chip lit — and no `mouseMoved` delivery is needed, which matters because
    /// a popup menu owned by a non-active app is not a reliable source of `mouseMoved:`.
    private func updateHoveredChipFromPointer() {
        let index = hover.pointerInRow.flatMap { chipIndex(at: $0) }
        if CommandLine.arguments.contains("--hover-log") {
            let local = hover.pointerInRow.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "outside"
            DemoLog.write("chiprow pointer=\(local) -> chip=\(index.map(String.init) ?? "none") was=\(hoveredChip.map(String.init) ?? "none") rects=\(chipRects.count)")
        }
        if index != hoveredChip { hoveredChip = index; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, let index = chipIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onSelect?(Self.values[index])
        // keep the menu open: the newly active chip is the feedback
    }

    private func chipIndex(at point: NSPoint) -> Int? {
        for (index, rect) in chipRects.enumerated() where rect.contains(point) { return index }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, rect) in chipRects.enumerated() {
            let value = Self.values[index]
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            let isActive = currentLimit == value
            let isHovered = hoveredChip == index
            if isActive {
                NSColor.controlAccentColor.setFill()
                path.fill()
            } else if isHovered && isEnabled {
                NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.6).setFill()
                path.fill()
            } else {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
                path.fill()
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = "\(value)%" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? NSColor.white
                    : (isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor),
                .paragraphStyle: paragraph,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                      withAttributes: attributes)
        }
        super.draw(dirtyRect)
    }
}

/// A plain, clickable text row ("Charge to Full Now").
final class ActionRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    var onSelect: (() -> Void)?

    init(title: String, enabled: Bool = true) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leading),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isEnabled = enabled
        hover.onExit = { [weak self] in self?.setHovered(false) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var isEnabled = true
    private lazy var hover = RowHoverTracker(row: self)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
        hover.pointerEntered()
    }
    override func mouseExited(with event: NSEvent) { hover.pointerExited() }

    private func setHovered(_ value: Bool) {
        guard value != isHovered else { return }
        isHovered = value
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        onSelect?()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && isEnabled {
            NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.55).setFill()
            let pill = bounds.insetBy(dx: 5, dy: 2)
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
