# System DC Power Supply — macOS

A native macOS application for controlling and logging from HP / Agilent /
Keysight system DC power supplies over RS-232:

**66312A · 66332A · 6631B · 6632B · 6633B · 6634B · 6611C · 6612C · 6613C · 6614C**

![The main window driving a simulated 6632B at 12 V into a load that holds it in
constant current: the readout across the top, the instrument's facts in the
strip below it, the control boxes in two columns on the left, and the live
voltage trace over the event list on the right](screen.jpg)

**User guide:** [English](docs/guide.en.md) · [русский](docs/guide.ru.md) —
from the cable and the port settings through to the protections, the menu bar and
Shortcuts. This README covers how the thing is built and why; the guide covers
using it.

Companion project: [agmult](https://github.com/enthru/agmult), the same treatment for the 34401A
multimeter. Between them, a shortcut can sweep a supply and read a meter.

Written from scratch in Swift and SwiftUI. It takes its feature set and panel
design from [Nirav Patel's Windows
application](https://github.com/Niravk1997/663x2A-663xB-661xC-System-DC-Power-Supply-Software)
(C# / WPF), which served as the basis and inspiration for what this kind of tool
should do — see [CREDITS.md](CREDITS.md). No code was carried over: the serial
layer, threading model, graphing, simulator and tests are all original.

## Requirements

- macOS 14 or later
- Xcode command line tools (Swift 6). A full Xcode is needed only for the
  Shortcuts actions — see [Automation](#automation).
- A USB-to-RS-232 adapter **and a null-modem adapter or cable** — or nothing at
  all, if you use the built-in simulator

## Build and run

```sh
swift build                  # build everything
swift test                   # 80 tests, including a full loop against the simulator
./Scripts/make-app.sh        # assemble build/AgilentPSU.app
open build/AgilentPSU.app
```

`swift run AgilentPSU` also works, but the assembled bundle gets a proper Dock
icon and menu bar.

The icon itself is not in the repository. Put a square `icon.png` in the root and
`make-app.sh` turns it into the bundle's `.icns`; without one the app takes the
generic icon and everything else works the same.

## Trying it without hardware

The package ships a SCPI-speaking simulator of a 6632B. It models the CV/CC
crossover against a resistive load, OVP and OCP trips, the status registers, the
error queue and the front-panel display, and it presents itself on a
pseudo-terminal — so the application talks to it through the same termios serial
path it would use for a real supply.

In the app: **Config ▸ Start Built-in Simulator**, then **Connect**.

Standalone, for scripting or for pointing other software at it:

```sh
swift run agpsu-sim --load 55.5
# Simulated HP6632B ready.
#   Device path : /dev/ttys004
```

## Connecting real hardware

1. Wire it up: supply's serial port → null-modem adapter → RS-232 cable → USB
   adapter → Mac. A straight-through cable will not work.
2. On the supply's front panel: `INIF RS232`, baud 9600, parity None, flow None,
   language SCPI.
3. In the app: **Config ▸ Select Serial Port…**, pick the `/dev/cu.*` device,
   leave the defaults at 9600 8N1, and press **Connect**.

Use the `cu.*` device, never the matching `tty.*` one — the latter waits for
carrier detect and appears to hang. macOS has built-in drivers for FTDI and
CDC-ACM adapters; PL2303 and CH340 clones need the vendor driver installed
before they show up.

## What it does

- **The window** — the readout across the top, the instrument's facts in a strip
  under it, the controls in a grid that takes two columns when there is width
  for them, and the right-hand side given over to a live trace over the event
  list. The controls were five boxes stacked in one narrow column, which meant
  scrolling past three of them to reach the fourth while half a wide window sat
  empty.
- **Live readout** — measured voltage and current, calculated power, set points,
  regulation mode (CV / CC / CVCC / −CC / Dis), protection state. Auto-ranges to
  milli-units, with the same thresholds as the original.
- **Control** — set voltage and current in V/mV and A/mA with stepped entry,
  output on/off, OVP level, OCP enable, clear protection, front-panel messages,
  device reset, error-queue readout.
- **Protections** — OVP and OCP run inside the supply. UVP and UCP are enforced
  by the application from the measured values, so they act no faster than the
  update rate; the panel and this README both say so, because it matters.
- **Graphs** — a trace in the main window, plus three windows of their own
  (voltage, current, power) with per-graph colours, themes, markers for set
  point / OVP / UVP, sample-number or time x-axis, and PNG / CSV export. Both
  draw the same `SeriesChart`, so the pane in the window is the graph window in
  miniature rather than a second drawing that happens to look different.
- **Logging** — measurements to text or CSV and every event-list entry to text,
  named `date-model-port-…` as on Windows, written to `~/Documents/AgilentPSU`
  or a folder you choose.
- **Menu bar** — the measured volts and amps in the menu bar, with the set
  points, the protection state and an output-off switch behind them, for
  watching a supply from inside whatever you are actually working in.
- **Notifications** — a banner when a protection trips, when the output falls
  into constant current, or when the supply stops answering. Each kind
  separately, and by default only while another application is in front.
- **Shortcuts** — read the supply, set a voltage or a current limit, switch the
  output, clear a trip or reset the history, as actions any automation can call.
  See below.
- **Settings are remembered** — panel colours, the polling plan and update rate,
  every graph's appearance and history size, display ranges, the logger, and the
  port that worked last time. Set points are deliberately *not*: restoring a
  panel is not the same as restoring an output, and a supply that came up putting
  yesterday's volts across today's board would be a hazard, not a convenience.

## Automation

The app publishes six App Intents, so the supply becomes something a script can
drive and question:

| Action | What it does |
| --- | --- |
| Read the Supply | Measured volts, amps or watts, or either set point, as a number |
| Set Output Voltage | Sets the voltage set point |
| Set Current Limit | Sets the current limit |
| Switch the Output | Turns the output on or off |
| Clear Protection | Clears a trip once the cause is gone |
| Reset History and Counters | Starts a run over |

They appear in Shortcuts, Spotlight and Siri once the app has been launched
once. All six work on the running application — the serial port is open in that
one process and cannot be shared — so an intent that arrives while the app is
closed will launch it, and one that arrives with no supply connected says so
rather than inventing a number. A set point beyond the supply's rating is
refused here rather than sent down the wire to settle in the error queue.

Step the voltage in a loop and read the current back after each step and you
have an I-V curve taken by a shortcut rather than by hand; with
[agmult](https://github.com/enthru/agmult) alongside, one shortcut can drive the supply and read the
meter. Switching the output *on* from an unattended shortcut puts volts across
whatever is wired up, which is the point of it for a sweep and worth knowing
before it runs while nobody is at the bench.

**Building this part needs a full Xcode**, not just the command line tools.
Shortcuts finds actions through a `Metadata.appintents` bundle that Xcode
generates from a build phase Swift Package Manager has no equivalent of;
`Scripts/make-app.sh` does the same two steps by hand — the compiler writes out
the compile-time constants of everything conforming to an App Intents protocol,
and `appintentsmetadataprocessor` turns those into the bundle. Without Xcode the
script says so and carries on: the app works, Shortcuts just cannot see it.

## Keyboard shortcuts

The usual Mac ones, so the app behaves like a Mac app:

| Shortcut | What it does |
| --- | --- |
| ⌘, | Settings — panel colours, polling plan and update rate, graph appearance and history size, data logger |
| ⌘O | Select serial port |
| ⇧⌘D | Disconnect |
| ⇧⌘R | Reset device |
| ⌘S | Save the front window: the event list in the main window, the samples in a graph window |
| ⌘K | Clear the event list |
| ⌘0 | Main window |
| ⌘1 ⌘2 ⌘3 | Voltage, current and power graphs |
| ⌘W ⌘M | Close and minimise, as everywhere |
| ⇧⌘/ | General Help, which lists these too |
| ⌘Q | Quit |

In the connection window ⌘R rescans the ports, Return connects and Esc closes
it. Text fields keep the standard editing shortcuts.

The Settings window and the menus drive the same state — whichever you reach
for, the other follows.

## How it is put together

| Target | What it is |
| --- | --- |
| `PSUCore` | Serial port (POSIX termios), port enumeration (IOKit), SCPI protocol, polling worker, controller, logging. No UI. |
| `PSUSimulator` | Pseudo-terminal plus a simulated instrument. |
| `AgilentPSUKit` | All SwiftUI views, the Settings window and the menu bar. |
| `AgilentPSU` | The executable — one line, calls into the kit. |
| `agpsu-sim` | Command-line simulator. |

Serial I/O never touches the main thread. The worker owns the port, runs one
polling pass per update interval and hands the main actor a finished snapshot;
commands from the UI go the other way through a queue. The Windows original
drove the supply from a UI-thread timer, where a slow or unplugged device froze
the window.

## Differences from the Windows application

- Ports are `/dev/cu.*` device paths, not COM numbers.
- Mark and Space parity are not offered — Darwin's termios has no `CMSPAR`, and
  these supplies do not use them.
- Measurement responses are parsed as numbers rather than screened by string
  length, so unusual but valid replies are no longer discarded.
- Status registers are decoded bit by bit, so combined trips (say OV *and* OCP)
  are reported individually instead of falling through to "unknown".
- Graphs use Swift Charts. Long histories are decimated for drawing with the
  minima and maxima preserved, so a 2M-sample graph stays responsive and spikes
  still show; exports contain every retained sample. Axis labels are formatted
  rather than left to the viewer's locale — a comma-decimal Mac would otherwise
  put "4,19" on the axis above a readout saying "4.190V" — and their colour comes
  from the plot rather than from the system appearance, which in dark mode was
  drawing white numbers on the white field the themes paint.
- The window resizes into its space: two columns of controls when there is width
  for them, one when there is not, and a scroller that appears only when
  something is actually below the fold.
- The "Edit" menu is called **Counters**, which is what it always contained.
- Log files default to `~/Documents/AgilentPSU` rather than the working
  directory.
- A menu bar item, notification banners and Shortcuts actions have no equivalent
  in the original, which predates all three.
- Settings persist between launches; the Windows version started from its
  defaults every time.

## Tests

```sh
swift test
```

The suite covers SCPI parsing and formatting, status decoding, the sample
buffer and its decimation, and — over a real serial connection to the simulator
— identification, set-point read-back, the CV/CC crossover, OVP and OCP trips,
current-range overload, the error queue, reset, the full controller polling
loop, soft UVP/UCP tripping, and log-file output.

The layout is tested rather than eyeballed: the control grid is measured with
`NSHostingView.fittingSize` at the width the default window gives it and has to
fit without scrolling, and the same measurement at a narrow width has to come
out taller — proof the two columns collapsed to one rather than silently
overflowing.

The automation surface is covered without any of it touching the system: the
alert centre is built with its delivery, its permission request and its "is the
app in front" test injected, so a test asserts on what would have been posted
rather than posting it. The controller side is checked against the simulator —
a protection trip and a soft UVP trip each raise one banner, the crossover into
constant current raises exactly one however long it lasts, and an alert nobody
asked for is never even built. The intents are run end to end against the
simulated supply: set a voltage, switch the output on, read the current back.

Interface tests render the views off-screen; set `AGPSU_RENDER_DIR` to write the
images out:

```sh
AGPSU_RENDER_DIR=/tmp/render swift test --filter InterfaceRenderTests
```

`ImageRenderer` cannot draw AppKit-backed controls (`List`, `Form`, `TextField`,
`HSplitView`), so the main, connection and Settings windows come out partly
blank — those tests exist to evaluate every view body and binding, not to check
pixels.
The readout panel, graphs and help windows render fully.

## Licence

MIT — see [LICENSE](LICENSE). Attribution for the design this project builds on
is in [CREDITS.md](CREDITS.md).
