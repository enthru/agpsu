import SwiftUI

struct SerialHelpView: View {
    var body: some View {
        HelpScroll(title: "Serial Connection Help") {
            HelpSection("What you need") {
                Text("A USB-to-RS-232 adapter, plus a null-modem adapter or cable. The supply's serial port is male, so a female-to-female null modem adapter and a male RS-232 cable are the usual combination; a gender changer may be needed depending on your adapter.")
                Text("Power Supply serial port  →  null modem adapter/cable  →  RS-232 cable  →  USB adapter  →  Mac")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HelpSection("Drivers and device names") {
                Text("macOS ships drivers for FTDI and Apple's own CDC-ACM class. Prolific PL2303 and WCH CH340 adapters usually need the vendor's driver. Once the driver is loaded the adapter shows up as a callout device such as /dev/cu.usbserial-1410 — that is what this application connects to.")
                Text("Use the cu.* device, never the matching tty.* one: the tty device waits for carrier detect and will appear to hang.")
            }

            HelpSection("Port settings") {
                Text("Both sides must agree. This application defaults to the supply's own defaults:")
                Text("Baud rate 9600 · Data bits 8 · Parity None · Stop bits 1 · Flow control None")
                    .font(.system(size: 12, design: .monospaced))
                Text("On the supply's front panel set: INIF RS232, baud 9600, parity None, flow None, language SCPI. Mark and Space parity are not offered here because macOS termios has no equivalent; the 663x supplies do not use them.")
            }

            HelpSection("If nothing answers") {
                Text("Check the null-modem adapter first — a straight-through cable will not work. Then confirm the supply's interface is set to RS232 rather than GPIB, and that no other program (a terminal emulator, a previous copy of this app) is holding the port open.")
                Text("No hardware to hand? Config ▸ Start Built-in Simulator creates a virtual instrument on a pseudo-terminal, and every part of the application works against it.")
            }
        }
    }
}

struct GeneralHelpView: View {
    var body: some View {
        HelpScroll(title: "General Help") {
            HelpSection("The window") {
                Text("Top to bottom: the readout, a strip carrying the instrument's own facts — model, ratings, port, polling rate and the last entry from its error queue — and then a split, controls on the left and the live trace over the event list on the right. Every divider can be dragged.")
                Text("The five control boxes take two columns when the pane is wide enough and one when it is not, so nothing is hidden below the fold on a normal window. When something is, the column grows a scroll bar and keeps it: an area that cannot scroll does not show one, so an empty margin means there is genuinely nothing else.")
                Text("The trace is the graph window in miniature — same colours, same theme, same markers — with a switch for voltage, current or power and a button that opens the full window with its export and settings.")
                Text("Anything the application refuses to do, such as an OVP above the supply's rating, is said in orange in the strip under the readout rather than only in the event list.")
            }

            HelpSection("Keyboard shortcuts") {
                ShortcutTable(rows: [
                    .init(keys: "\u{2318},", meaning: "Settings"),
                    .init(keys: "\u{2318}O", meaning: "Select serial port"),
                    .init(keys: "\u{21E7}\u{2318}D", meaning: "Disconnect"),
                    .init(keys: "\u{21E7}\u{2318}R", meaning: "Reset device"),
                    .init(keys: "\u{2318}S", meaning: "Save the front window \u{2014} the event list, or a graph's samples"),
                    .init(keys: "\u{2318}K", meaning: "Clear the event list"),
                    .init(keys: "\u{2318}0", meaning: "Main window"),
                    .init(keys: "\u{2318}1  \u{2318}2  \u{2318}3", meaning: "Voltage, current and power graphs"),
                    .init(keys: "\u{2318}W  \u{2318}M", meaning: "Close and minimise the front window"),
                    .init(keys: "\u{21E7}\u{2318}/", meaning: "This help"),
                    .init(keys: "\u{2318}Q", meaning: "Quit"),
                ])
                Text("In the connection window: \u{2318}R rescans the ports, Return connects, Esc closes.")
            }
            HelpSection("Settings") {
                Text("\u{2318}, opens Settings, which gathers the preferences that are otherwise spread across the menus: panel colours, the polling plan and update rate, per-graph appearance and history size, and the data logger. The menus still work \u{2014} both drive the same state.")
            }
            HelpSection("Config") {
                Text("Select Serial Port — opens the connection window. Reset Device — sends *RST to the connected supply. Start Built-in Simulator — runs a virtual 6632B for testing without hardware.")
            }
            HelpSection("Measurements") {
                Text("Measure Current Range — the supply has two internal current shunts; the low range is far more accurate below 20 mA but reads overload above it.")
                Text("The individual measurement toggles switch off the corresponding query. Turning off what you do not need makes the remaining readings faster, since every reading is a separate serial round trip.")
                Text("Voltage / Current / Power Auto Range — chooses when the readout switches to milli-units.")
            }
            HelpSection("Graphs") {
                Text("The trace in the main window plus three windows of their own. Each keeps its own history, whose size is set per graph from 50K to 2M samples. Curves are decimated for drawing so that even a 2M-sample history stays responsive; Save Data exports every retained sample.")
            }
            HelpSection("Output and protection") {
                Text("The Voltage and Current boxes set the supply's output. The Output box turns the output on and off and holds UVP and UCP.")
                Text("UVP and UCP are enforced by this application from the measured values, not by the supply. They can only act as fast as the update rate, so do not rely on them to protect anything delicate.")
                Text("OVP and OCP are real hardware protections inside the supply. Clear Protect resets a trip once the cause is gone.")
            }
            HelpSection("Data Logger") {
                Text("Save Output writes measured voltage and current to a text or CSV file. Save Status writes every event-list entry — user input, errors and protection trips. Files are named by date, model and port, and go to the chosen folder (~/Documents/AgilentPSU by default).")
            }
            HelpSection("List") {
                Text("Auto Scroll keeps the newest entry in view. Update List pauses new entries without affecting Save Status. Add Meas Volt & Curr appends every measurement pair to the list.")
            }

            HelpSection("Watching without the window") {
                Text("The menu bar item shows the measured volts and amps next to a small bolt, at the right-hand end of the menu bar with the other status items — the clock, the battery, Wi-Fi. It updates twice a second, which is as fast as a number in a menu bar can be read, and shows a dash when no supply is connected. Click it for the set points, the protection state and the way back here; it also carries an output-off switch, which is the one thing worth reaching for without looking. Settings ▸ General turns it off.")
                Text("If you cannot find it: this application has a long menu bar of its own, and on a Mac with a notch macOS silently hides the status items that no longer fit. Switch to the Finder for a moment — its menus are short — and the item has room to appear.")
                Text("Notification banners cover three events: a protection trip, the output falling out of constant voltage into constant current, and the supply ceasing to answer. Each can be switched on separately in Settings ▸ General, and they are off until asked for. By default they appear only while another application is in front, since a banner over the window that already says the same thing is noise.")
                Text("The constant-current banner is raised on the crossover, not on the state: a supply can sit in CC for hours quite happily, and one banner per polling pass would be a fault of its own.")
            }

            HelpSection("Shortcuts and automation") {
                Text("Six actions are published to Shortcuts, Spotlight and Siri: Read the Supply, Set Output Voltage, Set Current Limit, Switch the Output, Clear Protection and Reset History. Stepping the voltage in a loop and reading the current back after each step is an I-V curve taken by a shortcut rather than by hand — and with a meter alongside, one shortcut can drive both.")
                Text("They work on the running application — the serial port is open in this one process and cannot be shared — so an action that arrives while the app is closed launches it, and one that arrives with no supply connected says so rather than inventing a number. A set point beyond the supply's rating is refused here rather than sent down the wire to end up in the error queue.")
                Text("Switching the output on from a shortcut puts volts across whatever is wired up, unattended. That is the point of it for a sweep, and worth remembering before a shortcut runs while nobody is at the bench.")
                Text("The actions appear only in a build made with a full Xcode installed. Shortcuts finds them through a metadata bundle that Scripts/make-app.sh generates; without Xcode the script says it skipped that step.")
            }

            HelpSection("What is remembered") {
                Text("Panel colours, the polling plan and update rate, every graph's appearance and history size, the display ranges, the logger settings and the last port used are all written back a moment after you change them, and restored at the next launch.")
                Text("Set points are not. Restoring a panel is not the same as restoring an output: a supply that came up putting yesterday's volts across whatever is now on the bench would be a hazard rather than a convenience. The set values are read from the supply when you connect.")
            }
        }
    }
}

struct CreditsView: View {
    var body: some View {
        HelpScroll(title: "Credits") {
            HelpSection("This macOS version") {
                Text("A native SwiftUI port for macOS, with a serial layer built directly on POSIX termios and graphs drawn with Swift Charts.")
            }
            HelpSection("Original Windows application") {
                Text("663x2A / 663xB / 661xC System DC Power Supply Software by Nirav Patel (Niravk1997), released under the MIT licence.")
                Link("github.com/Niravk1997/663x2A-663xB-661xC-System-DC-Power-Supply-Software",
                     destination: URL(string: "https://github.com/Niravk1997/663x2A-663xB-661xC-System-DC-Power-Supply-Software")!)
            }
            HelpSection("Graphing") {
                Text("The Windows original used the ScottPlot library by Scott Harden. This port uses Apple's Swift Charts instead, so ScottPlot is not bundled — but the graphs it inspired are.")
            }
            HelpSection("Supported models") {
                Text("66312A, 66332A, 6631B, 6632B, 6633B, 6634B, 6611C, 6612C, 6613C and 6614C.")
            }
        }
    }
}

// MARK: - Layout helpers

private struct HelpScroll<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title2).bold()
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}

/// The shortcut list in General Help, kept in step with the menu bar by hand.
private struct ShortcutTable: View {
    struct Row: Identifiable {
        let keys: String
        let meaning: String
        var id: String { keys }
    }

    let rows: [Row]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.keys)
                        .font(.system(size: 12, design: .monospaced))
                        .gridColumnAlignment(.leading)
                    Text(row.meaning)
                }
            }
        }
    }
}

private struct HelpSection<Content: View>: View {
    let heading: String
    @ViewBuilder let content: Content

    init(_ heading: String, @ViewBuilder content: () -> Content) {
        self.heading = heading
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.headline)
            content
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
