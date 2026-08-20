# 663x / 661x Power Supply — user guide

[Русская версия](guide.ru.md)

The application drives HP / Agilent / Keysight system DC power supplies —
**66312A · 66332A · 6631B · 6632B · 6633B · 6634B · 6611C · 6612C · 6613C ·
6614C** — over RS-232: it sets voltage and current, follows the regulation mode
and the protections, draws graphs and writes logs. This guide is about using it.
How the project is put together, and why it was built the way it was, is in the
[README](../README.md).

---

## Contents

1. [Getting started](#getting-started)
2. [Connecting the supply](#connecting-the-supply)
3. [The main window](#the-main-window)
4. [Setting voltage and current](#setting-voltage-and-current)
5. [Protections](#protections)
6. [Polling and update rate](#polling-and-update-rate)
7. [Graphs](#graphs)
8. [Logging to file](#logging-to-file)
9. [Watching without the window](#watching-without-the-window)
10. [What is remembered](#what-is-remembered)
11. [Keyboard shortcuts](#keyboard-shortcuts)
12. [When something is wrong](#when-something-is-wrong)

---

## Getting started

The instrument is optional. A 6632B simulator is built in: it models the CV/CC
crossover against a resistive load, OVP and OCP trips, the status registers, the
error queue and the front panel. Everything works against it — control, graphs,
logs, automation.

**Build and run:**

```sh
swift build                  # build
./Scripts/make-app.sh        # assemble AgilentPSU.app
open build/AgilentPSU.app
```

**Try it without hardware:** **Config ▸ Start Built-in Simulator**. A virtual
supply appears on a pseudo-terminal; press Connect in the connection window.

---

## Connecting the supply

### What you need

- a USB-to-RS-232 adapter;
- **a null-modem adapter or cable**.

The second is not a quibble. The supply's serial port is wired as DTE, and so is
the adapter at the computer, so a straight-through cable joins transmitter to
transmitter and nothing whatsoever happens.

The supply's port is male, so the usual combination is a female-to-female
null-modem adapter plus a male RS-232 cable. Depending on your adapter a gender
changer may be needed as well.

### Setting up the supply

On the front panel: **`INIF RS232`**, 9600 baud, parity None, flow control None,
language **SCPI**.

The language matters. These supplies power up in whichever language they were
left in, and in compatibility mode they do not understand the commands used
here. The application sends `SYST:LANG SCPI` when it connects, but if the panel
is locked to another mode it is easier to set it by hand.

The application's defaults match the factory ones: **9600 baud, 8 data bits,
parity None, one stop bit, no flow control**. Mark and Space parity are not
offered: macOS termios has no equivalent, and these supplies do not use them.

### Choosing the port

**⌘O**, or **Config ▸ Select Serial Port…**. The list holds `/dev/cu.*` devices.
Take the `cu.*` one, never the matching `tty.*`: the tty device waits for carrier
detect and will appear to have hung.

macOS handles FTDI and CDC-ACM adapters by itself; PL2303 and CH340 clones need
the vendor driver before they appear in the list at all.

Buttons in that window: **Device Info** asks the supply `*IDN?` without taking it
over; **Reset Device** sends `*RST`; **Connect** starts a session. The port that
worked last time is offered again, together with its line settings — press
Return.

---

## The main window

Top to bottom: the readout, a strip of facts about the instrument, and then the
window splits — controls on the left, the live graph over the event list on the
right. Every divider can be dragged.

### The readout

At the top, dressed as the instrument's own display:

- **measured voltage and current** in large digits, with the set points (`Set:`)
  underneath;
- the **regulation mode**: `CV` (holding voltage), `CC` (up against the current
  limit), `CVCC` (the crossover), `-CC` (sinking current, acting as a load),
  `Dis` (output off);
- `UVP`, `UCP`, `OVP`, `OCP` — the protection thresholds;
- **power**, the product of the two measured values.

Milli-units appear automatically; the thresholds are set in **Settings ▸ General
▸ Reading Format** separately for volts, amps and watts — the same choices the
Windows menus offered.

The panel's text and background colours are in **Settings ▸ General ▸ Output
Panel**, or the **Output Panel** menu.

### The instrument strip

Under the readout: the connection indicator, the model, the rated maximum
voltage and current, the port name, the polling-rate field, and the last entry
from the supply's error queue with a **Get** button. If the application refuses
to do something — an OVP above the supply's rating, say — the message appears
here as an orange band rather than in a box that can be scrolled out of sight.

Until a supply is connected, a **Connect…** button sits at the right-hand end of
the strip.

### The controls

On the left. Five boxes — Voltage, Current, Output, Protection, Front Panel —
laid out in **two columns** when there is width for them and one when there is
not. All of it fits an ordinary window without scrolling; if the window is narrow
or short, a scroll bar appears — a real one with its own strip, not the macOS
overlay that fades after a second. No bar means there is genuinely nothing below.

### The graph and the event list

On the right, split again.

At the top, a live graph of the same quantity the separate windows draw: same
colours, same theme, same markers. The **Voltage / Current / Power** switch
chooses what to show; **Open Window** opens the full-size window with its export
and settings. Until samples arrive, instead of an empty white field it says what
is missing.

Underneath, the record of everything that happened: input, errors, protection
trips and, if you want, every measurement pair. The line format is `text,time`,
as in the Windows version.

- **Auto Scroll** keeps the newest line in view;
- **Update List** pauses the list without affecting the log file;
- **Add Meas Volt & Curr** appends every measurement to the list;
- **⌘K** clears it, **⌘S** saves it as a text file.

### The status bar

Session time, the output state with an indicator, the sample counters for voltage
and current, indicators for logging and for a tripped protection, and the "Update
Speed" bar, which fills as samples arrive and resets; its scale is set in the
**Counters** menu or in Settings.

---

## Setting voltage and current

The **Voltage** and **Current** boxes on the left. Type a value or step it with
the arrows using the chosen increment; the units switch between V and mV (A and
mA). **Enter** sends it.

The application checks the value against what the supply is rated for — read when
it connects, and shown in the strip — and does not send anything obviously out of
range, which would otherwise settle silently in the instrument's error queue.

The **Output** box turns the output on and off. The software protections UVP and
UCP live there too; see below.

The **Front Panel** box writes text on the supply's own display, returns it to
normal and blanks it altogether. Useful when several identical instruments are on
the bench.

---

## Protections

### Hardware: OVP and OCP

**OVP** (over-voltage) and **OCP** (over-current) run **inside the supply**,
without the computer, and act immediately. OVP takes a value; OCP is switched on
and off. After a trip the output stays off until **Clear Protect** is pressed —
and the cause is gone.

The status register is decoded bit by bit, so simultaneous trips (OV and OCP,
say) are each reported in their own message rather than collapsing into "unknown
fault".

### Software: UVP and UCP

**UVP** and **UCP** protect against voltage and current falling *below* a
threshold. The supply has nothing of the sort; the application enforces them by
comparing the measured values with the threshold. Hence the consequence, which
matters more than the feature:

> They act no faster than the polling loop. At one pass a second, up to a second
> passes between the voltage falling and the output going off. Do not rely on
> them to protect anything delicate.

Having fired, the protection switches the output off, writes a line with the
measured values into the list and **disarms itself** — otherwise it would fire
again on the first zero reading that follows.

The beep on a trip is the **Beep on trip** checkbox in the Protection box.

---

## Polling and update rate

Every polling pass is several separate requests over the serial line, and the
time it takes is their sum. So **Settings ▸ Polling** lets you switch off what
you do not need at the moment:

| Request | What it gives |
| --- | --- |
| Measure voltage | The measured voltage |
| Measure current | The measured current |
| CV / CC / Dis status | The regulation mode |
| Protection status | The state of the protections |
| Set volt & set curr | The set points, read back |
| Set OVP & OCP values | The protection thresholds |

**Update Rate** is the pause between passes in seconds, from 0.05 to an hour.

**Measure Current Range** — the supply has two internal shunts. The low range
(20 mA) is markedly more accurate at small currents but reads overload (`OVLD`)
above it.

Serial traffic never runs on the main thread: the port belongs to a worker that
makes one pass per interval and hands over a finished snapshot. In the Windows
original the polling lived in a UI timer, where a slow or unplugged instrument
froze the window.

---

## Graphs

Three live windows — voltage (**⌘1**), current (**⌘2**), power (**⌘3**). Each
keeps its own history, from 50 thousand to 2 million samples.

- **Curve colour, plot background and figure background** separately, plus the
  four presets from the original.
- **X axis** — sample number or time.
- **Y axis** — automatic or set by hand.
- **Markers** on the voltage graph: the set point, the OVP level, the UVP level.
  The labels sit on the plot, so they are given the plot's own background and
  drawn after every line: otherwise the curve runs through the text exactly when
  the graph is worth looking at, and the OVP dashes strike through the set-point
  label — on a well-adjusted supply there are a hundred millivolts between them.
  Adjacent labels are pushed to opposite edges of the plot.
- **Save Image** writes a PNG, **Save Data** a CSV.

Axis labels are drawn in a colour chosen against the plot rather than by the
system: macOS dark mode would otherwise make them white on the white field the
standard themes paint. And the numbers always use a period, like the readings.

A long history is decimated for drawing with local minima and maxima preserved: a
two-million-point graph stays responsive and spikes survive. Exports contain
**every** retained sample, undecimated.

---

## Logging to file

**Data Logger** in the menus, or **Settings ▸ Logging**:

- **Save Output to Text File** — measured voltage and current;
- **Save Output to CSV File** — the same as CSV;
- **Save Status to Text File** — every line of the event list.

File names are made from the date, model and port, as in the Windows version. The
default folder is `~/Documents/AgilentPSU`, and you can choose another.

---

## Watching without the window

### The menu bar

<a id="the-menu-bar"></a>

The application puts an item in the **macOS menu bar** — the one along the top of
the screen. Look for it on the **right**, among the other status items: near the
clock, the battery, Wi-Fi. It is a small bolt with the measured volts and amps
beside it, for example `4.190V 41.9mA`. With no supply connected there is a dash
instead.

It updates twice a second. More often is pointless: a number changing faster than
that cannot be read in a menu bar, and the width of the item would twitch on
every digit, dragging its neighbours along with it.

Clicking it opens a menu: the model, the regulation mode and output state, the
measured values and the power, the set points, OVP, the session time and the
sample count. Below that: **Switch Output Off**, **Clear Protection**, the ways
back to the main window and the graph, and connect or disconnect.

The output can be switched off from the menu bar but not on. Killing the bench
without looking is worth having; putting volts back across whatever is connected
without looking is not.

The item itself is switched off in **Settings ▸ General ▸ Menu Bar**.

**Cannot find it?** That happens, and it is not always a fault. This application
has a long menu bar of its own (Config, Counters, Measurements, Graphs, Output
Panel, Data Logger, List plus the system ones), and on a Mac with a notch macOS
silently hides the status items that no longer fit. Switch to the Finder — its
menus are short, the room appears and so does the item. If you have a lot of
status items in general, utilities such as Ice or Bartender help.

### Notifications

Banners for three events:

| Event | When it arrives |
| --- | --- |
| Protection tripped | OV, OCP, over-temperature or a sense fault — the supply has shut its output down |
| Output went to constant current | The load began taking the whole current limit |
| Connection lost | The supply stopped answering; the session has ended |

Each is switched on separately in **Settings ▸ General ▸ Alerts** — they are
different sorts of event. A protection trip has already happened and the output
is already off; the crossover into CC is usually the first sign that something
under test is not well; a lost connection ends a run that has been going for
hours.

Notifications are **off** by default: permission to interrupt you is earned, not
asked for on first launch. Switching them on is the moment the system asks. Also
by default banners appear only when another application is in front: a banner
over the window that says the same thing in large digits is noise, not news.

The constant-current banner arrives **on entering** that mode rather than every
second while it lasts: a supply can sit in CC for hours quite happily.

### Shortcuts and automation

The application publishes six actions to Shortcuts, Spotlight and Siri:

| Action | What it does |
| --- | --- |
| Read the Supply | Returns voltage, current, power or a set point as a number |
| Set Output Voltage | Sets the voltage |
| Set Current Limit | Sets the current limit |
| Switch the Output | Turns the output on or off |
| Clear Protection | Clears a protection trip |
| Reset History and Counters | Starts a run over |

This is what the whole thing was for: step the voltage, wait, read the current
back, in a loop, and out comes an **I-V curve** taken by a script rather than by
hand. If a [multimeter](https://github.com/enthru/agmult) is working alongside,
one shortcut can drive both instruments.

All of them work on the **running** application — the serial port is open in that
one process and cannot be shared — so an action that arrives while the app is
closed launches it, and one that arrives with no supply connected says so
honestly instead of inventing a number. A value beyond the supply's rating is
refused here rather than sent down the wire to settle in the error queue.

> Switching the output on from a script puts volts across whatever is connected,
> unattended. That is exactly what a sweep needs, but it is worth knowing in
> advance.

> The actions only appear in a build made on a machine with a full Xcode.
> Shortcuts finds them through a metadata bundle that `Scripts/make-app.sh`
> generates; without Xcode the script says plainly that it skipped that step.

---

## What is remembered

Panel colours, the polling plan and update rate, every graph's appearance and
history size, the milli-unit thresholds, the logger settings, the state of the
list and the port you connected from last time — all written a moment after you
change them and restored at the next launch.

**The set voltage and current are not remembered**, and that is deliberate.
Restoring a panel is not the same as restoring an output: a supply that came up
putting yesterday's volts across whatever is on the bench today would be a hazard
rather than a convenience. The set values are read from the instrument itself
when you connect.

---

## Keyboard shortcuts

| Shortcut | What it does |
| --- | --- |
| ⌘, | Settings |
| ⌘O | Select serial port |
| ⇧⌘D | Disconnect |
| ⇧⌘R | Reset the device |
| ⌘S | Save the front window: the event list, or a graph's samples |
| ⌘K | Clear the event list |
| ⌘0 | Main window |
| ⌘1 ⌘2 ⌘3 | Voltage, current and power graphs |
| ⌘W ⌘M | Close and minimise |
| ⇧⌘/ | Help |
| ⌘Q | Quit |

In the connection window: **⌘R** rescans the ports, **Return** connects, **Esc**
closes it.

Settings and the menus drive the same state: whichever you reach for, the other
follows.

---

## When something is wrong

**The supply does not answer.** Check the null-modem adapter — a straight-through
cable will not work. Then: the supply's interface is set to RS232 rather than
GPIB; the language is SCPI; no other program (a terminal, a previous copy of this
one) is holding the port.

**The port list is empty, or the port is missing.** The device only appears once
the adapter's driver is loaded. PL2303 and CH340 need one installed separately.

**Readings arrive but the current says `OVLD`.** The low current measurement
range (20 mA) is selected and more than that is flowing. **Measurements ▸ Measure
Current Range ▸ High**.

**The output will not come on.** Most likely a protection has tripped: look at
the `Protection` line on the panel and at the event list. **Clear Protect** —
after the cause is gone.

**UVP trips immediately after switching on.** The threshold is compared with the
measured value, and at the moment of switching on it is still zero. Set UVP after
the output has come up.

**The window froze.** It should not: the traffic runs on its own thread. If it
does, look at the event list — there will be a `Connection lost` line.

**Not all the control boxes are visible.** The divider between the two halves of
the window drags with the mouse; if there is still not enough room, the column
scrolls — the bar appears by itself when there is something to scroll.

**Something is going into the error queue.** The **Get** button beside the error
text in the strip under the readout reads the next entry from the instrument.

**The menu bar item is missing.** See [above](#the-menu-bar).
