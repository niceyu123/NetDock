import XCTest
import Network
#if os(iOS)
import UIKit
#endif

private final class EchoEndpoint: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "org.netdock.ui-test.echo")
    private var connections: [NWConnection] = []
    private let udp: Bool
    init(ready: XCTestExpectation, udp: Bool = false) throws {
        self.udp = udp
        listener = try NWListener(using: udp ? .udp : .tcp, on: .any)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                if case .ready = state, let connection { self?.receive(connection) }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection) {
        if udp {
            connection.receiveMessage { [weak self, weak connection] data, _, _, error in
                guard let self, let connection, error == nil else { return }
                if let data { connection.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in }) }
                self.receive(connection)
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
            if !complete && error == nil { self.receive(connection) }
        }
    }
    func stop() {
        queue.sync {
            listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}

@MainActor
final class WorkspaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
    private func replace(_ element: XCUIElement, with value: String) {
        activate(element)
        #if os(macOS)
        element.typeKey("a", modifierFlags: .command)
        element.typeText(value)
        #else
        // Use the software keyboard on iOS; a synthesized hardware Command-A can leave
        // the simulator's Chinese input method waiting for an animation indefinitely.
        let oldValue = element.value as? String ?? ""
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + value)
        XCTAssertEqual(element.value as? String, value)
        #endif
    }
    private func launch(_ app: XCUIApplication) {
        app.launch()
        #if os(macOS)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        #endif
    }
    private func send(_ app: XCUIApplication) {
        activate(app.buttons["sendPayload"])
    }
    private func capture(_ name: String, app: XCUIApplication) {
        #if os(macOS)
        let screenshot = app.windows.firstMatch.screenshot()
        #else
        let screenshot = XCUIScreen.main.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NetDock-UI-Screenshots")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(name).png")
            try screenshot.pngRepresentation.write(to: file, options: .atomic)
            print("NETDOCK_SCREENSHOT: \(file.path)")
        } catch { XCTFail("Cannot save UI screenshot: \(error)") }
    }

    private func choose(_ identifier: String, value: String, app: XCUIApplication) {
        activate(app.descendants(matching: .any)[identifier].firstMatch)
        #if os(macOS)
        activate(app.menuItems[value].firstMatch)
        #else
        activate(app.buttons[value].firstMatch)
        #endif
    }

    private func finishEditing(_ app: XCUIApplication) {
        #if os(iOS)
        let done = app.buttons["dismissEditorKeyboard"]
        if done.exists { activate(done) }
        #endif
    }

    private func beginSession(_ mode: String = "TCP Client", app: XCUIApplication) {
        let identifiers = ["TCP Client": "tcpClient", "TCP Server": "tcpServer",
                           "UDP Client": "udpClient", "UDP Server": "udpServer"]
        guard let identifier = identifiers[mode] else { XCTFail("Unknown session mode: \(mode)"); return }
        activate(app.buttons["newSession.\(identifier)"])
        XCTAssertTrue(app.textFields["sessionName"].waitForExistence(timeout: 5))
    }

    private func finishEndpointEditing(_ app: XCUIApplication) {
        #if os(iOS)
        let done = app.buttons["dismissEndpointKeyboard"]
        if done.exists { activate(done) }
        #endif
    }

    private func firstSessionRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sessionRow.")).firstMatch
    }

    func testSidebarPresetsAllModesWithoutCreatingOnCancel() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "-reset-ui-state"]
        launch(app)
        XCTAssertFalse(app.descendants(matching: .any)["newSession"].firstMatch.exists)
        for mode in ["tcpClient", "tcpServer", "udpClient", "udpServer"] {
            XCTAssertTrue(app.buttons["newSession.\(mode)"].exists)
        }
        capture("session-sidebar-four-modes", app: app)
        for mode in ["TCP Client", "TCP Server", "UDP Client", "UDP Server"] {
            beginSession(mode, app: app)
            let picker = app.descendants(matching: .any)["sessionMode"].firstMatch
            XCTAssertTrue(picker.label.contains(mode) || String(describing: picker.value ?? "").contains(mode))
            if mode == "UDP Client" {
                let localPort = app.textFields["clientLocalPort"]
                let value = localPort.value as? String ?? ""
                XCTAssertTrue(value.isEmpty || value == localPort.placeholderValue)
            }
            capture("session-create-\(mode.replacingOccurrences(of: " ", with: "-"))", app: app)
            activate(app.buttons["cancelSession"])
        }
        XCTAssertFalse(app.buttons["toggleConnection"].exists)
    }

    func testInlineEndpointValidationPersistenceAndRealTCP() throws {
        let ready = expectation(description: "inline endpoint TCP echo listener")
        let endpoint = try EchoEndpoint(ready: ready)
        defer { endpoint.stop() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(endpoint.listener.port?.rawValue)
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "-reset-ui-state"]
        launch(app)
        beginSession(app: app)
        replace(app.textFields["sessionName"], with: "Inline TCP")
        finishEditing(app)
        activate(app.buttons["saveSession"])
        if !app.textFields["endpointPort"].waitForExistence(timeout: 3) {
            activate(firstSessionRow(app))
        }
        let hostField = app.textFields["endpointHost"]
        let portField = app.textFields["endpointPort"]
        XCTAssertTrue(portField.waitForExistence(timeout: 5))
        replace(portField, with: "0")
        finishEndpointEditing(app)
        activate(app.buttons["toggleConnection"])
        XCTAssertTrue(app.descendants(matching: .any)["endpointError"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(portField.isEnabled)
        capture("session-inline-invalid-port", app: app)
        #if os(macOS)
        firstSessionRow(app).rightClick()
        let sidebarStart = app.menuItems.matching(NSPredicate(format: "identifier BEGINSWITH %@", "toggleSession.")).firstMatch
        XCTAssertTrue(sidebarStart.waitForExistence(timeout: 3))
        activate(sidebarStart)
        // The sidebar action must also reject the draft without starting the old endpoint.
        XCTAssertEqual(portField.value as? String, "0")
        XCTAssertTrue(app.descendants(matching: .any)["endpointError"].firstMatch.exists)
        #endif
        replace(portField, with: String(port))
        replace(hostField, with: "bad/host")
        finishEndpointEditing(app)
        activate(app.buttons["saveEndpoint"])
        XCTAssertTrue(app.descendants(matching: .any)["endpointError"].firstMatch.exists)
        replace(hostField, with: "127.0.0.1")
        finishEndpointEditing(app)
        // Connecting must validate and save the draft instead of using the old port.
        activate(app.buttons["toggleConnection"])
        let state = app.descendants(matching: .any)["connectionState"]
        let connected = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已连接", "已连接"), evaluatedWith: state)
        wait(for: [connected], timeout: 8)
        XCTAssertFalse(hostField.isEnabled)
        XCTAssertFalse(portField.isEnabled)
        let payload = app.textViews["payload"]
        activate(payload); payload.typeText("inline")
        send(app)
        let returned = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "TX 6 · RX 6", "TX 6 · RX 6"), evaluatedWith: app.staticTexts["trafficCounters"])
        wait(for: [returned], timeout: 8)
        capture("session-inline-connected-real-tcp", app: app)
        activate(app.buttons["toggleConnection"])
        let stopped = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已停止", "已停止"), evaluatedWith: state)
        wait(for: [stopped], timeout: 5)
        XCTAssertTrue(portField.isEnabled)
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        launch(app)
        activate(firstSessionRow(app))
        XCTAssertTrue(portField.waitForExistence(timeout: 5))
        XCTAssertEqual(portField.value as? String, String(port))
        XCTAssertEqual(hostField.value as? String, "127.0.0.1")
        capture("session-inline-persisted", app: app)
    }

    func testLanguageAndAppearancePersistAcrossRelaunch() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "-reset-ui-state"]
        launch(app)
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 8))
        activate(app.buttons["settings"])
        choose("languagePicker", value: "English", app: app)
        choose("appearancePicker", value: "Dark", app: app)
        XCTAssertTrue(app.buttons["closeSettings"].waitForExistence(timeout: 3))
        capture("05-settings-en-dark", app: app)
        activate(app.buttons["closeSettings"])
        XCTAssertTrue(app.staticTexts["Tools"].exists)
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        launch(app)
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Tools"].exists)
        activate(app.buttons["settings"])
        let appearance = app.descendants(matching: .any)["appearancePicker"].firstMatch
        XCTAssertTrue(appearance.label.contains("Dark") || String(describing: appearance.value ?? "").contains("Dark"))
        capture("06-relaunched-en-dark", app: app)
        choose("appearancePicker", value: "Light", app: app)
        capture("07-settings-en-light", app: app)
        choose("languagePicker", value: "简体中文", app: app)
        choose("appearancePicker", value: "跟随系统", app: app)
        capture("08-settings-zh-system", app: app)
        activate(app.buttons["closeSettings"])
        XCTAssertTrue(app.staticTexts["工具"].exists)
    }

    func testRealUDPHexRoundTripAndScreenshots() throws {
        let ready = expectation(description: "real UDP echo listener")
        let endpoint = try EchoEndpoint(ready: ready, udp: true)
        defer { endpoint.stop() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(endpoint.listener.port?.rawValue)
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "-reset-ui-state"]
        launch(app)
        #if os(iOS)
        XCTAssertFalse(app.buttons["connectionMonitor"].exists)
        #endif
        beginSession("UDP Client", app: app)
        XCTAssertTrue(app.textFields["sessionName"].waitForExistence(timeout: 5))
        replace(app.textFields["sessionName"], with: "UDP Live")
        finishEditing(app)
        choose("sessionMode", value: "UDP Client", app: app)
        replace(app.textFields["port"], with: String(port))
        finishEditing(app)
        activate(app.buttons["saveSession"])
        if !app.buttons["toggleConnection"].waitForExistence(timeout: 3) { activate(firstSessionRow(app)) }
        activate(app.buttons["toggleConnection"])
        let state = app.descendants(matching: .any)["connectionState"]
        let readyState = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "本地已就绪", "本地已就绪"), evaluatedWith: state)
        wait(for: [readyState], timeout: 8)
        #if os(macOS)
        activate(try XCTUnwrap(app.radioButtons.matching(identifier: "HEX").allElementsBoundByIndex.last))
        activate(app.radioButtons.matching(identifier: "HEX").firstMatch)
        #else
        activate(try XCTUnwrap(app.buttons.matching(identifier: "HEX").allElementsBoundByIndex.last))
        #endif
        let editor = app.textViews["payload"]
        activate(editor); editor.typeText("00 FF E4 B8 AD")
        send(app)
        let counters = app.staticTexts["trafficCounters"]
        let received = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "TX 5 · RX 5", "TX 5 · RX 5"), evaluatedWith: counters)
        wait(for: [received], timeout: 8)
        capture("m2-udp-hex-roundtrip", app: app)
        activate(app.buttons["periodicSend"])
        XCTAssertTrue(app.textFields["loopInterval"].waitForExistence(timeout: 5))
        replace(app.textFields["loopInterval"], with: "100")
        activate(app.descendants(matching: .any)["continuousSend"].firstMatch)
        replace(app.textFields["loopCount"], with: "3")
        activate(app.buttons["startRepeat"])
        let loopState = app.staticTexts["loopState"]
        let completed = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已完成", "已完成"), evaluatedWith: loopState)
        wait(for: [completed], timeout: 8)
        capture("m3-periodic-three-datagrams", app: app)
        activate(app.buttons["closeLoop"])
        let total = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "TX 20 · RX 20", "TX 20 · RX 20"), evaluatedWith: counters)
        wait(for: [total], timeout: 8)
        activate(app.buttons["commands"])
        XCTAssertTrue(app.textFields["commandTitle"].waitForExistence(timeout: 5))
        replace(app.textFields["commandTitle"], with: "UDP Binary Command")
        activate(app.buttons["saveCommand"])
        XCTAssertTrue(app.staticTexts["UDP Binary Command"].waitForExistence(timeout: 5))
        capture("m3-saved-command", app: app)
        activate(app.buttons["closeCommands"])
        activate(app.buttons["toggleConnection"])
        let stopped = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已停止", "已停止"), evaluatedWith: state)
        wait(for: [stopped], timeout: 5)
    }

    #if os(macOS)
    func testConnectionMonitorShowsRealOwnedUDPPort() throws {
        let reserved = expectation(description: "UDP port reservation")
        let endpoint = try EchoEndpoint(ready: reserved, udp: true)
        wait(for: [reserved], timeout: 5)
        let port = try XCTUnwrap(endpoint.listener.port?.rawValue)
        let cancelled = expectation(description: "UDP reservation released")
        endpoint.listener.stateUpdateHandler = { if case .cancelled = $0 { cancelled.fulfill() } }
        endpoint.listener.cancel(); wait(for: [cancelled], timeout: 5); endpoint.stop()
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "-reset-ui-state"]
        launch(app)
        beginSession("UDP Server", app: app)
        replace(app.textFields["sessionName"], with: "Monitored UDP")
        choose("sessionMode", value: "UDP Server", app: app)
        replace(app.textFields["port"], with: String(port))
        activate(app.buttons["saveSession"])
        if !app.buttons["toggleConnection"].waitForExistence(timeout: 3) { activate(firstSessionRow(app)) }
        activate(app.buttons["toggleConnection"])
        let listening = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "监听中", "监听中"), evaluatedWith: app.descendants(matching: .any)["connectionState"])
        wait(for: [listening], timeout: 8)
        activate(app.descendants(matching: .any)["connectionMonitor"].firstMatch)
        XCTAssertTrue(app.textFields["monitorPortQuery"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.textFields["monitorPortQuery"].isHittable)
        XCTAssertTrue(app.textFields["monitorSearch"].isHittable)
        replace(app.textFields["monitorPortQuery"], with: String(port))
        activate(app.buttons["monitorRefresh"])
        let table = app.tables["monitorTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        let ownedRow = table.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", String(port), String(port))).firstMatch
        XCTAssertTrue(ownedRow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["monitorScope"].exists)
        // Keep screenshots scoped to the real test listener, including after clearing search.
        let search = app.textFields["monitorSearch"]
        XCTAssertTrue(search.exists)
        search.typeKey("f", modifierFlags: .command)
        search.typeText("netdock \(port) udp")
        XCTAssertEqual(search.value as? String, "netdock \(port) udp")
        XCTAssertTrue(ownedRow.waitForExistence(timeout: 5))
        capture("monitor-search-service-port-zh", app: app)
        replace(search, with: "no-such-netdock-service")
        let noMatches = expectation(for: NSPredicate { _, _ in !ownedRow.exists }, evaluatedWith: app)
        wait(for: [noMatches], timeout: 5)
        activate(app.buttons["monitorClearSearch"])
        XCTAssertEqual(search.value as? String, "")
        XCTAssertTrue(ownedRow.waitForExistence(timeout: 5))
        replace(search, with: String(port))
        // The general search must match the port without the dedicated local-port filter.
        replace(app.textFields["monitorPortQuery"], with: "")
        XCTAssertTrue(ownedRow.waitForExistence(timeout: 5))
        replace(app.textFields["monitorPortQuery"], with: String(port))
        activate(app.buttons["monitorClearSearch"])
        activate(app.buttons["monitorFieldHelp"])
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "系统可读的 socket 所属进程名")).firstMatch.waitForExistence(timeout: 5))
        capture("monitor-field-descriptions-zh", app: app)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        activate(ownedRow)
        capture("monitor-owned-udp-port-zh", app: app)
        activate(app.buttons["monitorPause"])
        choose("monitorInterval", value: "1 秒", app: app)
        activate(app.buttons["monitorRefresh"])
        capture("monitor-paused-manual-refresh", app: app)
        activate(app.buttons["settings"])
        choose("languagePicker", value: "English", app: app)
        choose("appearancePicker", value: "Dark", app: app)
        activate(app.buttons["closeSettings"])
        XCTAssertEqual(app.descendants(matching: .any)["connectionMonitor"].firstMatch.label, "Connection Monitor")
        replace(search, with: "NETDOCK \(port)")
        XCTAssertTrue(ownedRow.waitForExistence(timeout: 5))
        capture("monitor-en-dark", app: app)
        activate(firstSessionRow(app))
        XCTAssertTrue(app.buttons["toggleConnection"].waitForExistence(timeout: 5))
        // Navigation to the monitor must leave the original UDP listener running.
        let retained = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Listening", "Listening"), evaluatedWith: app.descendants(matching: .any)["connectionState"])
        wait(for: [retained], timeout: 5)
        activate(app.buttons["toggleConnection"])
    }
    #endif

    func testRealTCPRoundTripAndScreenshots() throws {
        let ready = expectation(description: "real TCP echo listener")
        let endpoint = try EchoEndpoint(ready: ready)
        defer { endpoint.stop() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(endpoint.listener.port?.rawValue)
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "-reset-ui-state"]
        launch(app)
        XCTAssertTrue(app.buttons["newSession.tcpClient"].waitForExistence(timeout: 8))
        capture("01-empty-zh-light", app: app)
        beginSession(app: app)
        let name = app.textFields["sessionName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replace(name, with: "TCP Loopback")
        replace(app.textFields["port"], with: String(port))
        finishEditing(app)
        activate(app.buttons["saveSession"])
        // NavigationSplitView may keep the list visible in compact environments.
        if !app.buttons["toggleConnection"].waitForExistence(timeout: 3) {
            activate(firstSessionRow(app))
        }
        XCTAssertTrue(app.buttons["toggleConnection"].waitForExistence(timeout: 5))
        capture("02-workspace-idle", app: app)
        activate(app.buttons["toggleConnection"])
        let state = app.descendants(matching: .any)["connectionState"]
        let connected = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已连接", "已连接"), evaluatedWith: state)
        wait(for: [connected], timeout: 8)
        let editor = app.textViews["payload"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        activate(editor); editor.typeText("NetDock live TCP")
        XCTAssertTrue(app.buttons["sendPayload"].isEnabled)
        send(app)
        capture("03-sent-before-check", app: app)
        let echoed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "NetDock live TCP", "NetDock live TCP"))
        let echo = expectation(for: NSPredicate(format: "count >= 1"), evaluatedWith: echoed)
        let counters = app.staticTexts["trafficCounters"]
        let returned = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "TX 16 · RX 16", "TX 16 · RX 16"), evaluatedWith: counters)
        // List virtualizes offscreen rows, especially while the phone keyboard is visible.
        wait(for: [echo, returned], timeout: 8)
        capture("03-real-tcp-tx-rx-keyboard", app: app)
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            let landscape = expectation(for: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return frame.width > frame.height && app.buttons["toggleConnection"].isHittable
            }, evaluatedWith: app)
            wait(for: [landscape], timeout: 8)
            capture("03-ipad-landscape-tcp", app: app)
            XCUIDevice.shared.orientation = .portrait
            let portrait = expectation(for: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return frame.height > frame.width && app.buttons["toggleConnection"].isHittable
            }, evaluatedWith: app)
            wait(for: [portrait], timeout: 8)
        }
        #endif
        activate(app.buttons["toggleConnection"])
        let stopped = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已停止", "已停止"), evaluatedWith: state)
        wait(for: [stopped], timeout: 5)
        capture("04-disconnected", app: app)
    }

    func testServerReceivesAndBroadcastsToRealClient() throws {
        // Ask the OS for an unused port, then release that listener before the App binds it.
        let reserved = expectation(description: "port reservation")
        let reservation = try EchoEndpoint(ready: reserved)
        wait(for: [reserved], timeout: 5)
        let port = try XCTUnwrap(reservation.listener.port?.rawValue)
        let cancelled = expectation(description: "release reserved listener")
        reservation.listener.stateUpdateHandler = { state in if case .cancelled = state { cancelled.fulfill() } }
        reservation.listener.cancel()
        wait(for: [cancelled], timeout: 5)
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-ui-testing", "-reset-ui-state"]
        launch(app)
        beginSession("TCP Server", app: app)
        XCTAssertTrue(app.textFields["sessionName"].waitForExistence(timeout: 5))
        replace(app.textFields["sessionName"], with: "TCP Server Live")
        finishEditing(app)
        choose("sessionMode", value: "TCP Server", app: app)
        replace(app.textFields["port"], with: String(port))
        finishEditing(app)
        activate(app.buttons["saveSession"])
        if !app.buttons["toggleConnection"].waitForExistence(timeout: 3) {
            activate(firstSessionRow(app))
        }
        activate(app.buttons["toggleConnection"])
        let state = app.descendants(matching: .any)["connectionState"]
        let listening = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "监听中", "监听中"), evaluatedWith: state)
        wait(for: [listening], timeout: 8)
        let received = expectation(description: "real client received server reply")
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: port), using: .tcp)
        defer { client.cancel() }
        client.stateUpdateHandler = { [weak client] status in
            guard case .ready = status, let client else { return }
            client.send(content: Data("Client to server".utf8), completion: .contentProcessed { _ in })
            // This test protocol expects exactly 12 bytes, independent of TCP read boundaries.
            client.receive(minimumIncompleteLength: 12, maximumLength: 12) { data, _, _, _ in
                if data == Data("Server reply".utf8) { received.fulfill() }
            }
        }
        client.start(queue: DispatchQueue(label: "org.netdock.ui-test.client"))
        let inbound = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Client to server", "Client to server")).firstMatch
        XCTAssertTrue(inbound.waitForExistence(timeout: 8))
        activate(app.textViews["payload"]); app.textViews["payload"].typeText("Server reply")
        send(app)
        capture("09-server-sent-before-check", app: app)
        print("NETDOCK_SERVER_UI: \(app.debugDescription)")
        wait(for: [received], timeout: 8)
        capture("09-server-real-client-broadcast", app: app)
        activate(app.buttons["toggleConnection"])
    }
}
