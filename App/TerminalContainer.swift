import SwiftTerm
import SwiftUI
import UIKit

@MainActor
enum TerminalFont {
    private static let key = "terminalFontSize"
    static let range: ClosedRange<CGFloat> = 8...28

    /// Phone portrait lands under herdr's 64-column mobile threshold; iPad gets the desktop layout.
    static var size: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: key)
            if stored > 0 { return stored }
            return UIDevice.current.userInterfaceIdiom == .pad ? 15 : 13
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: key) }
    }

    static func font() -> UIFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

final class HerdrTerminalView: TerminalView {
    /// Off after the user hides the keyboard, so taps only click instead of raising it again.
    var keyboardEnabled = true

    /// UI tests launch with `-steadyCaret`: XCTest waits for animations to settle before every
    /// action, and SwiftTerm's caret blink is a repeating animation that never does.
    private static let steadyCaret = ProcessInfo.processInfo.arguments.contains("-steadyCaret")

    override init(frame: CGRect, font: UIFont?) {
        super.init(frame: frame, font: font)
        nativeBackgroundColor = .black
        nativeForegroundColor = .white
        // A dark keyboard and key bar sit under a black terminal in either system appearance.
        keyboardAppearance = .dark
        inputAccessoryView = KeyBar(terminal: self)
        if Self.steadyCaret { cursorStyleChanged(source: getTerminal(), newStyle: getTerminal().options.cursorStyle) }
    }

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        guard Self.steadyCaret else { return super.cursorStyleChanged(source: source, newStyle: newStyle) }
        let steady: CursorStyle = switch newStyle {
        case .blinkBlock, .steadyBlock: .steadyBlock
        case .blinkUnderline, .steadyUnderline: .steadyUnderline
        case .blinkBar, .steadyBar: .steadyBar
        }
        super.cursorStyleChanged(source: source, newStyle: steady)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { keyboardEnabled && super.canBecomeFirstResponder }

    func showKeyboard() {
        keyboardEnabled = true
        _ = becomeFirstResponder()
    }

    func hideKeyboard() {
        keyboardEnabled = false
        _ = resignFirstResponder()
    }

    /// Feeds host output. SwiftTerm (through 1.20 and main as of 2026-09-19) sets the mouse
    /// encoding to X10 on *any* encoding DECRST, even one that isn't active, and Windows ConPTY
    /// sends `?1016l` right after `?1006h`. Clicks then reach Windows hosts as X10 bytes, which
    /// ConPTY types into the pane as text.
    /// ponytail: drops only that exact sequence, so one split across two reads slips through.
    /// Delete this once SwiftTerm's cmdResetMode only clears the encoding that is active.
    func feedHost(_ bytes: [UInt8]) {
        var bytes = bytes
        while let range = bytes.firstRange(of: Self.resetSGRPixelMouse) { bytes.removeSubrange(range) }
        feed(byteArray: bytes[...])
    }

    private static let resetSGRPixelMouse: [UInt8] = [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x31, 0x36, 0x6c]  // ESC [ ? 1016 l

    /// SwiftTerm spends the first tap on an unfocused view becoming first responder, so that
    /// tap never reaches herdr. Report it ourselves as a left click when mouse reporting is on.
    func sendClick(at point: CGPoint) {
        let terminal = getTerminal()
        guard terminal.mouseMode != .off, let cell = cell(at: point) else { return }
        for release in terminal.mouseMode == .x10 ? [false] : [false, true] {
            let flags = terminal.encodeButton(button: 0, release: release, shift: false, meta: false, control: false)
            terminal.sendEvent(buttonFlags: flags, x: cell.col, y: cell.row, pixelX: Int(point.x), pixelY: cell.pixelY)
        }
    }

    /// Touch drags are mouse drags once herdr enables mouse reporting, so pane scrollback needs
    /// explicit wheel events. Positive `lines` scroll toward earlier output.
    func sendWheel(lines: Int, at point: CGPoint) {
        let terminal = getTerminal()
        guard terminal.mouseMode != .off, lines != 0, let cell = cell(at: point) else { return }
        let flags = terminal.encodeButton(button: lines > 0 ? 4 : 5, release: false, shift: false, meta: false, control: false)
        for _ in 0..<abs(lines) {
            terminal.sendEvent(buttonFlags: flags, x: cell.col, y: cell.row, pixelX: Int(point.x), pixelY: cell.pixelY)
        }
    }

    var cellHeight: CGFloat {
        let rows = getTerminal().rows
        return rows > 0 ? getOptimalFrameSize().height / CGFloat(rows) : 1
    }

    /// The visible grid cell under a point in this view's (scrolled) coordinates.
    private func cell(at point: CGPoint) -> (col: Int, row: Int, pixelY: Int)? {
        let terminal = getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return nil }
        let grid = getOptimalFrameSize().size
        let y = point.y - contentOffset.y
        let col = min(terminal.cols - 1, max(0, Int(point.x / (grid.width / CGFloat(terminal.cols)))))
        let row = min(terminal.rows - 1, max(0, Int(y / (grid.height / CGFloat(terminal.rows)))))
        return (col, row, Int(y))
    }
}

/// Hosts a session's long-lived terminal view; a new container adopts it on every appearance.
struct TerminalContainer: UIViewRepresentable {
    let session: HostSession

    func makeUIView(context: Context) -> TerminalHostingView { TerminalHostingView(session: session) }

    func updateUIView(_ view: TerminalHostingView, context: Context) {}
}

final class TerminalHostingView: UIView, UIGestureRecognizerDelegate {
    private let session: HostSession
    private var pinchStartSize: CGFloat = 0
    private var scrollCarry: CGFloat = 0

    init(session: HostSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .black
        let terminal = session.terminalView
        if terminal.font.pointSize != TerminalFont.size { terminal.font = TerminalFont.font() }
        addSubview(terminal)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        // Two fingers (or an iPad trackpad/wheel) scroll herdr; one finger stays a mouse drag.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        scroll.minimumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        scroll.delegate = self
        addGestureRecognizer(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let terminal = session.terminalView
        guard terminal.superview === self, bounds.width > 0, bounds.height > 0 else { return }
        if terminal.frame != bounds {
            terminal.frame = bounds
            terminal.layoutIfNeeded()
        }
        session.viewDidLayout()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let terminal = session.terminalView
        guard recognizer.state == .ended, !terminal.isFirstResponder else { return }
        terminal.sendClick(at: recognizer.location(in: terminal))
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        let terminal = session.terminalView
        guard recognizer.state == .began || recognizer.state == .changed else {
            scrollCarry = 0
            return
        }
        scrollCarry += recognizer.translation(in: terminal).y
        recognizer.setTranslation(.zero, in: terminal)
        let lines = Int(scrollCarry / terminal.cellHeight)
        guard lines != 0 else { return }
        scrollCarry -= CGFloat(lines) * terminal.cellHeight
        terminal.sendWheel(lines: lines, at: recognizer.location(in: terminal))
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartSize = TerminalFont.size
        case .changed:
            let size = min(max((pinchStartSize * recognizer.scale).rounded(), TerminalFont.range.lowerBound),
                           TerminalFont.range.upperBound)
            guard size != TerminalFont.size else { return }
            TerminalFont.size = size
            session.terminalView.font = TerminalFont.font()
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Keyboard accessory row tuned for herdr: its ctrl+b prefix, esc, tab, sticky ctrl, arrows.
final class KeyBar: UIInputView {
    private weak var terminal: HerdrTerminalView?
    private let ctrlButton = UIButton(configuration: .gray())

    init(terminal: HerdrTerminalView) {
        self.terminal = terminal
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: phone ? 44 : 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        overrideUserInterfaceStyle = .dark

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(key("⌃B", label: "herdr prefix, control B") { $0.send([0x02]) })
        stack.addArrangedSubview(key("esc", label: "escape") { $0.send([0x1b]) })
        configure(ctrlButton, title: "ctrl", label: "control, sticky")
        ctrlButton.addAction(UIAction { [weak self] _ in self?.toggleControl() }, for: .touchUpInside)
        stack.addArrangedSubview(ctrlButton)
        stack.addArrangedSubview(key("tab", label: "tab") { $0.send([0x09]) })
        for (symbol, name, code) in [("arrow.left", "left", UInt8(ascii: "D")), ("arrow.up", "up", UInt8(ascii: "A")),
                                     ("arrow.down", "down", UInt8(ascii: "B")), ("arrow.right", "right", UInt8(ascii: "C"))] {
            stack.addArrangedSubview(key(symbol: symbol, label: name) { view in
                // Application cursor mode (DECCKM) changes the arrow encoding.
                let intro: UInt8 = view.getTerminal().applicationCursor ? 0x4f : 0x5b
                view.send([0x1b, intro, code])
            })
        }
        for text in ["|", "~", "/", "-"] {
            stack.addArrangedSubview(key(text, label: text) { $0.send(txt: text) })
        }
        stack.addArrangedSubview(key(symbol: "keyboard.chevron.compact.down", label: "hide keyboard") { $0.hideKeyboard() })

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])

        // SwiftTerm clears controlModifier after the next key it sends.
        NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: terminal,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControl() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func toggleControl() {
        guard let terminal else { return }
        terminal.controlModifier.toggle()
        refreshControl()
    }

    private func refreshControl() {
        ctrlButton.configuration = (terminal?.controlModifier ?? false) ? .filled() : .gray()
        configure(ctrlButton, title: "ctrl", label: "control, sticky")
    }

    private func key(_ title: String? = nil, symbol: String? = nil, label: String,
                     action: @escaping (HerdrTerminalView) -> Void) -> UIButton {
        let button = UIButton(configuration: .gray())
        configure(button, title: title, symbol: symbol, label: label)
        button.addAction(UIAction { [weak self] _ in
            guard let terminal = self?.terminal else { return }
            UIDevice.current.playInputClick()
            action(terminal)
        }, for: .touchUpInside)
        return button
    }

    private func configure(_ button: UIButton, title: String? = nil, symbol: String? = nil, label: String) {
        var config = button.configuration ?? .gray()
        if let title {
            config.attributedTitle = AttributedString(title, attributes: .init([
                .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .medium),
            ]))
        }
        if let symbol { config.image = UIImage(systemName: symbol) }
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        button.configuration = config
        button.accessibilityLabel = label
    }
}

extension KeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
