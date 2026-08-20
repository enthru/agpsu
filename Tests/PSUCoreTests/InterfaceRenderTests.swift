import XCTest
import SwiftUI
@testable import PSUCore
@testable import PSUSimulator
@testable import AgilentPSUKit

/// Renders the real SwiftUI views off-screen against live simulator data.
///
/// This catches layout and binding faults that a logic-only test cannot, and the
/// rendered images are written to `AGPSU_RENDER_DIR` when that variable is set,
/// so the interface can be inspected without launching the app.
@MainActor
final class InterfaceRenderTests: XCTestCase {

    private var server: SimulatorServer!
    private var model: AppModel!

    override func setUp() async throws {
        server = try SimulatorServer()
        server.start()
        server.simulatedDevice.loadResistance = 55.5   // 4.19 V draws about 75 mA

        // An ephemeral store: a test run must not rewrite the user's own settings.
        model = AppModel(store: .ephemeral())
        model.controller.beeperEnabled = false
        model.controller.updateRate = 0.05

        let config = SerialConfig(path: server.devicePath, readTimeout: 2, writeTimeout: 2)
        let identity = try ConnectionProbe.identify(config: config)
        model.controller.connect(config: config, identity: identity)

        model.controller.setVoltage(4.19, inMillivolts: false)
        model.controller.setCurrent(0.3, inMilliamps: false)
        model.controller.setOVP(4.3)
        model.controller.toggleOutput()

        // Arm the software protections only once the output is regulating —
        // otherwise the first reading of 0 V trips UVP immediately.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.controller.voltageHistory.samples.count > 5 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        model.controller.setUVP(3.4)
        model.controller.setUCP(0.01)
    }

    override func tearDown() async throws {
        model?.controller.disconnect()
        server?.stop()
        model = nil
        server = nil
    }

    /// `ImageRenderer` cannot draw AppKit-backed controls (List, Form, TextField,
    /// HSplitView), so these two windows come out partly blank. Rendering them is
    /// still worth doing: it evaluates every view body and binding, which is
    /// where a mis-wired key path or a missing environment value would show up.
    func testMainWindowBuildsAndRenders() throws {
        let image = try render(MainView().environment(model), size: CGSize(width: 1200, height: 800))
        XCTAssertGreaterThan(image.size.width, 0)
        try write(image, named: "main-window.png")
    }

    /// The width of the default window, as declared by the scene.
    private static let defaultWindow = CGSize(width: 1280, height: 860)

    /// The controls have to fit the pane the default window gives them without
    /// scrolling — which is the whole point of arranging them in a grid.
    ///
    /// The width is taken from the split rather than assumed: the two halves
    /// share the window evenly, and a change to either pane's limits moves the
    /// divider without anything else noticing.
    func testControlGridFitsThePaneTheDefaultWindowGivesIt() throws {
        let paneWidth = try splitPaneWidths(atWindowWidth: Self.defaultWindow.width)[0]
        // The readout, the strip and the status bar take about 300 points of an
        // 860-tall window between them.
        let paneHeight = Self.defaultWindow.height - 300

        try write(try render(ControlGrid().environment(model),
                             size: CGSize(width: paneWidth, height: paneHeight)),
                  named: "control-grid.png")

        let needed = height(ofControlsAtWidth: paneWidth)
        XCTAssertLessThanOrEqual(needed, paneHeight,
                                 "the controls want \(needed) points and have \(paneHeight)")
    }

    /// And they have to be in *two* columns there. The pane is half the window,
    /// so a panel that grew by twenty points would quietly fold the grid into
    /// one tall column rather than break anything.
    func testTheDefaultWindowIsWideEnoughForTwoColumns() throws {
        let paneWidth = try splitPaneWidths(atWindowWidth: Self.defaultWindow.width)[0]
        let atDefault = height(ofControlsAtWidth: paneWidth)
        let oneColumn = height(ofControlsAtWidth: 330)
        XCTAssertLessThan(atDefault, oneColumn,
                          "the \(paneWidth)-point pane is laying the controls out in one column")
    }

    /// The panels were tightened until two columns fit the pane the window
    /// actually gives them: the rows used to carry a 190-point label spelling
    /// "UVP (UnderVoltage Protection):" out in full, which by itself was two
    /// thirds of a column.
    func testControlsCollapseToOneColumnWhenNarrow() throws {
        let narrow = height(ofControlsAtWidth: 330)
        let wide = height(ofControlsAtWidth: Self.defaultWindow.width / 2)
        XCTAssertGreaterThan(narrow, wide,
                             "one column (\(narrow)) has to be taller than two (\(wide))")
    }

    /// Height the control grid needs at a given width.
    ///
    /// The width is pinned inside the SwiftUI hierarchy rather than on the
    /// hosting view: `fittingSize` measures the content, and a frame set on the
    /// AppKit view outside it is not a constraint the layout ever sees.
    private func height(ofControlsAtWidth width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: ControlGrid().environment(model).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The scrolling column has to build and render whether or not its content
    /// overflows — the scroller is configured on the scroll view SwiftUI makes,
    /// which only exists once the thing is in a hierarchy.
    func testScrollingColumnRendersWithAndWithoutOverflow() throws {
        let cramped = try render(ScrollableColumn { ControlGrid() }.environment(model),
                                 size: CGSize(width: 330, height: 200))
        XCTAssertGreaterThan(cramped.size.width, 0)
        try write(cramped, named: "controls-overflowing.png")

        let roomy = try render(ScrollableColumn { ControlGrid() }.environment(model),
                               size: CGSize(width: 640, height: 700))
        XCTAssertGreaterThan(roomy.size.width, 0)
    }

    /// Widening the window has to widen both halves of the split, not just one.
    ///
    /// `HSplitView` is an `NSSplitView` underneath and AppKit resizes the pane
    /// with the lowest holding priority first, so the frames can be read out of
    /// the hierarchy rather than guessed at from a screenshot.
    func testBothHalvesOfTheSplitGrowWithTheWindow() throws {
        let narrow = try splitPaneWidths(atWindowWidth: 1000)
        let wide = try splitPaneWidths(atWindowWidth: 1400)
        XCTAssertEqual(narrow.count, 2)
        XCTAssertEqual(wide.count, 2)

        XCTAssertGreaterThan(wide[1], narrow[1], "the right-hand pane did not grow")
        XCTAssertGreaterThan(wide[0], narrow[0],
                             "the controls stayed at \(narrow[0]) points while the window gained 400")
    }

    /// The widths of the two halves of the main window's horizontal split, laid
    /// out inside a window of the given width.
    private func splitPaneWidths(atWindowWidth width: CGFloat) throws -> [CGFloat] {
        let host = NSHostingView(rootView: MainView().environment(model))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 820)
        // A window: NSSplitView only lays its panes out once it is in one.
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .resizable],
                              backing: .buffered,
                              defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let split = try XCTUnwrap(Self.horizontalSplitView(in: host), "no side-by-side split view found")
        return split.arrangedSubviews.map(\.frame.width)
    }

    /// The side-by-side split, which is the one whose dividers run vertically —
    /// the other `NSSplitView` in the window is the trace over the event list.
    private static func horizontalSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2 {
            return split
        }
        for subview in view.subviews {
            if let found = horizontalSplitView(in: subview) { return found }
        }
        return nil
    }

    /// The facts strip under the readout, which took the place of the Info box.
    func testInstrumentStripRenders() throws {
        XCTAssertTrue(model.controller.isConnected)
        try write(try render(InstrumentStrip().environment(model).frame(width: 900),
                             size: CGSize(width: 900, height: 40)),
                  named: "instrument-strip.png")
    }

    func testReadoutPanelShowsLiveValues() throws {
        XCTAssertTrue(model.controller.voltageIsValid, "the panel needs a real reading to show")
        XCTAssertEqual(model.controller.measuredVoltage, 4.19, accuracy: 0.05)

        let image = try render(ReadoutPanel().environment(model).frame(width: 880),
                               size: CGSize(width: 880, height: 220))
        try write(image, named: "readout-panel.png")
    }

    func testGraphWindowRenders() throws {
        let image = try render(GraphWindow(kind: .voltage).environment(model),
                               size: CGSize(width: 900, height: 560))
        try write(image, named: "voltage-graph.png")
    }

    func testConnectionWindowBuildsAndRenders() throws {
        let image = try render(ConnectionView().environment(model), size: CGSize(width: 700, height: 380))
        try write(image, named: "connection.png")
    }

    /// The Settings window (\u{2318},) — each pane is rendered on its own, since a
    /// TabView only builds the tab that is showing.
    func testSettingsWindowRenders() throws {
        try write(try render(SettingsView().environment(model), size: CGSize(width: 560, height: 420)),
                  named: "settings.png")
        try write(try render(GeneralSettings().environment(model), size: CGSize(width: 560, height: 420)),
                  named: "settings-general.png")
        try write(try render(PollingSettings().environment(model), size: CGSize(width: 560, height: 420)),
                  named: "settings-polling.png")
        try write(try render(GraphsSettings().environment(model), size: CGSize(width: 560, height: 480)),
                  named: "settings-graphs.png")
        try write(try render(LoggingSettings().environment(model), size: CGSize(width: 560, height: 420)),
                  named: "settings-logging.png")
    }

    /// The alert switches only exist once banners are on, so the pane is
    /// rendered both ways — the collapsed one is what everybody sees first.
    func testTheAlertSettingsRenderInBothStates() throws {
        try write(try render(GeneralSettings().environment(model), size: CGSize(width: 560, height: 560)),
                  named: "settings-alerts-off.png")

        model.alerts.isEnabled = true
        try write(try render(GeneralSettings().environment(model), size: CGSize(width: 560, height: 700)),
                  named: "settings-alerts-on.png")
        model.alerts.isEnabled = false
    }

    /// The menu bar item and the menu behind it, against a live supply.
    func testTheMenuBarItemRenders() throws {
        let readout = MenuBarReadout(controller: model.controller)
        readout.sample()
        XCTAssertTrue(readout.isConnected)
        XCTAssertTrue(readout.title.contains("V"), "the bar shows volts, not a placeholder")

        try write(try render(MenuBarLabel(readout: readout).padding(4), size: CGSize(width: 200, height: 30)),
                  named: "menu-bar-label.png")
        try write(try render(VStack(alignment: .leading) { MenuBarReadoutContent().environment(model) }
                                .padding(10),
                             size: CGSize(width: 320, height: 420)),
                  named: "menu-bar-menu.png")
    }

    /// A curve drawn straight through the marker labels — the case the plain
    /// annotation could not survive.
    func testGraphMarkersStayReadableUnderACurve() throws {
        let settings = model.settings(for: .voltage)
        settings.showOVPMarker = true
        settings.showUVPMarker = true
        XCTAssertTrue(settings.showSetMarker)
        XCTAssertGreaterThan(model.controller.voltageHistory.samples.count, 3, "there has to be a curve to obscure them")

        let image = try render(GraphWindow(kind: .voltage).environment(model),
                               size: CGSize(width: 900, height: 560))
        try write(image, named: "voltage-graph-markers.png")
    }

    func testHelpWindowsRender() throws {
        try write(try render(GeneralHelpView(), size: CGSize(width: 620, height: 620)), named: "help-general.png")
        try write(try render(SerialHelpView(), size: CGSize(width: 620, height: 620)), named: "help-serial.png")
    }

    // MARK: - Helpers

    private func render(_ view: some View, size: CGSize) throws -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage, "the view failed to render")
    }

    private func write(_ image: NSImage, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AGPSU_RENDER_DIR"] else { return }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(name)")
            return
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
}
