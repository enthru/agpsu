# Credits

## Basis and inspiration

This application was built on the groundwork of

> **663x2A / 663xB / 661xC System DC Power Supply Software** by Nirav Patel
> (Niravk1997) — <https://github.com/Niravk1997/663x2A-663xB-661xC-System-DC-Power-Supply-Software>

a Windows application in C# and WPF. It served as the reference for what a good
control program for these supplies should do: the feature set, the panel
layout, the menu structure, the idea of enforcing under-voltage and
under-current limits in software when the instrument itself offers none. Credit
for that design is his, and it is the reason this project had a clear target to
aim at from the first line.

## What this project is

An independent macOS implementation, written from scratch in Swift and SwiftUI.
No source code from the original was copied or translated — the two programs
share no lines, no types and no architecture. The serial layer, port
enumeration, threading model, graphing, instrument simulator, test suite and
application packaging are all original work here.

The instrument protocol is public: SCPI is an open standard (SCPI-1999,
IEEE 488.2), and the command set, status-register bit assignments and response
formats used here are documented in the *Agilent 663xA/663xB/661xC Programming
Guide*. Nothing about talking to these supplies is proprietary to any one
implementation.

## Libraries

The Windows original drew its graphs with
[ScottPlot](https://github.com/swharden/scottplot) by Scott Harden. This project
uses Apple's Swift Charts and does not bundle or link ScottPlot.

This package has no third-party dependencies. The serial layer is built directly
on POSIX `termios` and IOKit.

## Instruments

Supports the 66312A, 66332A, 6631B, 6632B, 6633B, 6634B, 6611C, 6612C, 6613C
and 6614C system DC power supplies.
