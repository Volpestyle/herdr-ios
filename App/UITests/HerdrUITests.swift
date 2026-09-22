import XCTest

/// Drives the app against a live host, adding it as "This Mac" through the editor if missing. Its
/// herdr session must be a throwaway one (never the host's default session: herdr sizes every
/// pane to the foreground client). Pass settings as TEST_RUNNER_<NAME> to xcodebuild:
/// HERDR_TEST_NAME, HERDR_TEST_HOST, HERDR_TEST_USER, HERDR_TEST_SESSION, HERDR_TEST_KILL_LINE,
/// EVIDENCE_DIR, EVIDENCE_TAG.
final class HerdrUITests: XCTestCase {
    private let app = XCUIApplication()
    private let env = ProcessInfo.processInfo.environment
    private var tag: String { env["EVIDENCE_TAG"] ?? "sim" }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-steadyCaret"]
        app.launch()
    }

    /// Writes this simulator's device key to $EVIDENCE_DIR/<tag>-device-key.pub for authorizing.
    func testDeviceKey() throws {
        showSidebar()
        app.buttons["Device Key"].tap()
        let key = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'ssh-ed25519 '")).firstMatch
        XCTAssert(key.waitForExistence(timeout: 10))
        print("DEVICE-KEY: \(key.label)")  // a device run can't write to the Mac; read it from the log
        if let dir = env["EVIDENCE_DIR"] {
            try key.label.write(toFile: "\(dir)/\(tag)-device-key.pub", atomically: true, encoding: .utf8)
        }
        snap("device-key")
        app.buttons["Done"].tap()
        app.buttons["Add Host"].firstMatch.tap()
        snap("add-host")
        app.buttons["Cancel"].tap()
    }

    func testLiveHerdr() throws {
        // iPad portrait can launch with the sidebar collapsed.
        let host = app.staticTexts[hostName].firstMatch
        if !host.waitForExistence(timeout: 3) { showSidebar() }
        if !host.waitForExistence(timeout: 3) { addHost() }
        XCTAssert(host.waitForExistence(timeout: 5))
        snap("hosts")
        host.tap()
        waitConnected()
        // A fresh simulator's keyboard opens with a one-time slide-to-type tutorial over the key bar.
        if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
        snap("connected-portrait")

        // Typing, then the up arrow recalls it: the host pane shows the marker printed twice.
        app.typeText("echo herdr-ios-typed\n")
        key("up")
        app.typeText("\n")
        // Sticky ctrl: the kill-line chord drops the half-typed line, so only the ok marker runs.
        // zsh binds ctrl+u; PowerShell's Windows edit mode cancels the line on ctrl+c instead.
        app.typeText("echo herdr-ios-ctrl-FAIL")
        key("control, sticky")
        app.typeText(env["HERDR_TEST_KILL_LINE"] ?? "u")
        app.typeText("echo herdr-ios-ctrl-ok\n")
        sleep(1)
        snap("typed")

        // The ctrl+b prefix: prefix+v splits the pane to the right.
        key("herdr prefix, control B")
        app.typeText("v")
        sleep(2)
        snap("prefix-split-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        snap("landscape")

        // Taps click: focus the left pane with the keyboard up, then the right one with it hidden.
        let terminal = app.otherElements["terminal"]
        terminal.coordinate(withNormalizedOffset: CGVector(dx: tapLeft, dy: 0.3)).tap()
        sleep(1)
        app.typeText("echo herdr-ios-tapped-left\n")
        key("hide keyboard")
        sleep(1)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.3)).tap()
        sleep(1)
        app.buttons["Keyboard"].tap()
        sleep(1)
        app.typeText("echo herdr-ios-tapped-right\n")
        sleep(1)
        snap("tapped-landscape")

        XCUIDevice.shared.orientation = .portrait
        sleep(3)
        snap("rotated-back-portrait")

        // Background long enough to drop the socket, then return: it reattaches on its own.
        XCUIDevice.shared.press(.home)
        sleep(8)
        app.activate()
        waitConnected()
        snap("reattached")
    }

    /// QR pairing through the URL scheme. The driver runs herdr-pair on the host, delivers its
    /// link with `simctl openurl` once $EVIDENCE_DIR/<tag>-pair-ready exists, and answers the
    /// approval prompt. HERDR_TEST_EXPECT=paired (default) lands in herdr without a trust prompt;
    /// any other value is text the failure message must contain.
    func testPairing() throws {
        let dir = try XCTUnwrap(env["EVIDENCE_DIR"])
        FileManager.default.createFile(atPath: "\(dir)/\(tag)-pair-ready", contents: nil)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        let pair = app.buttons["Pair"]
        let unusable = app.staticTexts["Can't Use This Code"]
        let deadline = Date().addingTimeInterval(90)
        while !pair.exists, !unusable.exists, Date() < deadline {
            if open.exists { open.tap() }
            sleep(1)
        }
        if open.exists { open.tap() }
        let expect = env["HERDR_TEST_EXPECT"] ?? "paired"
        if unusable.exists {  // rejected before any connection, e.g. an expired code
            snap("pair-invalid")
            XCTAssert(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expect)).firstMatch.exists)
            return
        }
        XCTAssert(pair.exists, "no pairing sheet")
        sleep(1)  // let the sheet finish presenting
        snap("pair-review")
        pair.tap()
        let waiting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Waiting for approval'")).firstMatch
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expect)).firstMatch
        // A host-key mismatch or pin conflict is refused before the approval step.
        let reached = Date().addingTimeInterval(30)
        while !waiting.exists, !(expect != "paired" && failure.exists), Date() < reached { sleep(1) }
        if waiting.exists {
            snap("pair-waiting")
            // What the phone asks the user to compare with the computer's approval prompt.
            let check = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "shows this device's key:")).firstMatch
            if check.exists {
                try? check.label.write(toFile: "\(dir)/\(tag)-device-check.txt", atomically: true, encoding: .utf8)
            }
        }
        if expect == "paired" {
            XCTAssert(waiting.exists, "never waited for approval")
            XCTAssert(waiting.waitForNonExistence(timeout: 150))
            waitConnected(trust: false)
            snap("pair-connected")
        } else {
            let failed = failure.waitForExistence(timeout: 150)
            snap("pair-failed")
            XCTAssert(failed, "no failure containing \(expect)")
        }
    }

    /// Host-key pinning against a throwaway sshd at $HERDR_TEST_ALT_PORT on 127.0.0.1.
    /// HERDR_TEST_STEP=first expects the first-use prompt; =changed runs after the host key was
    /// swapped and expects a refusal, then recovers through Forget Host Key.
    func testHostKeyPinning() throws {
        let host = app.staticTexts["Pinning Test"].firstMatch
        if !host.waitForExistence(timeout: 3) { showSidebar() }
        if !host.waitForExistence(timeout: 3) {
            addHost(name: "Pinning Test", hostname: "127.0.0.1", port: env["HERDR_TEST_ALT_PORT"] ?? "2222")
        }
        host.tap()
        if env["HERDR_TEST_STEP"] == "changed" {
            XCTAssert(app.navigationBars["Host Key Changed"].waitForExistence(timeout: 20))
            snap("host-key-changed")
            app.buttons["Close"].tap()
            XCTAssert(app.staticTexts["Couldn't Connect"].waitForExistence(timeout: 5))
            snap("host-key-changed-refused")

            // Back to the host list: the sidebar on iPad, a pop on iPhone.
            if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() } else { app.buttons["BackButton"].firstMatch.tap() }
            XCTAssert(host.waitForExistence(timeout: 5))
            host.press(forDuration: 1)
            app.buttons["Edit"].tap()
            app.buttons["Forget Host Key"].firstMatch.tap()
            snap("forget-host-key-confirm")
            // The confirmation is an action sheet on iPhone and a popover on iPad.
            let confirm = app.sheets.buttons["Forget Host Key"].exists
                ? app.sheets.buttons["Forget Host Key"] : app.popovers.buttons["Forget Host Key"]
            confirm.firstMatch.tap()
            app.buttons["Cancel"].tap()
            host.tap()
            app.buttons["Try Again"].firstMatch.tap()
        }
        XCTAssert(app.buttons["Trust"].waitForExistence(timeout: 20))
        snap(env["HERDR_TEST_STEP"] == "changed" ? "trust-after-forget" : "trust-host-key")
        app.buttons["Trust"].tap()
        waitConnected()
        snap("pinned-connected")
    }

    /// iPad portrait launches with the sidebar, and so the host list, collapsed.
    private func showSidebar() {
        if app.buttons["Show Sidebar"].waitForExistence(timeout: 2) { app.buttons["Show Sidebar"].tap() }
    }

    private var hostName: String { env["HERDR_TEST_NAME"] ?? "This Mac" }

    private func addHost(name: String? = nil, hostname: String? = nil, port: String? = nil) {
        app.buttons["Add Host"].firstMatch.tap()
        // Form fields are found by their placeholder prompts.
        for (prompt, value) in [("Studio Mac", name ?? hostName), ("my-mac or 100.x.y.z", hostname ?? env["HERDR_TEST_HOST"] ?? "100.103.220.58"),
                                ("james", env["HERDR_TEST_USER"] ?? "james"),
                                ("default", env["HERDR_TEST_SESSION"] ?? "herdr-ios-test")] {
            let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", prompt)).firstMatch
            field.tap()
            field.typeText(value)
        }
        if let port {
            let field = app.textFields.matching(NSPredicate(format: "value == '22'")).firstMatch
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + port)
        }
        snap("add-host-filled")
        app.buttons["Save"].tap()
    }

    /// Normalized x inside the left pane after the split, clear of herdr's sidebar.
    private var tapLeft: CGFloat { Double(env["TAP_LEFT"] ?? "") ?? 0.45 }

    private func key(_ label: String) {
        app.buttons[label].firstMatch.tap()
    }

    /// `trust: false` fails on a first-use prompt: a paired host is already pinned.
    private func waitConnected(trust: Bool = true, timeout: TimeInterval = 45) {
        let busy = ["Connecting…", "Reconnecting…"]
        var sawReconnect = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.buttons["Trust"].exists {
                snap("trust-host-key")
                XCTAssert(trust, "unexpected host-key prompt")
                app.buttons["Trust"].tap()
            }
            for failure in ["Couldn't Connect", "Session Ended", "Host Key Changed"] where app.staticTexts[failure].exists {
                snap("failed")
                XCTFail("\(failure): \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
                return
            }
            if app.staticTexts["Reconnecting…"].exists {
                if !sawReconnect { snap("reconnecting") }
                sawReconnect = true
            }
            if !busy.contains(where: { app.staticTexts[$0].exists }) {
                sleep(3)
                return
            }
            sleep(1)
        }
        XCTFail("never connected")
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["EVIDENCE_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(tag)-\(name).png"))
        }
    }
}
