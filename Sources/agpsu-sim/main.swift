import Foundation
import PSUSimulator

// Command line front end for the power supply simulator. Prints the device path
// to connect to and then traces the SCPI conversation until interrupted.

// Line-buffer stdout so the trace still appears when the output is piped to a
// file or another program rather than a terminal.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
var loadResistance = 10.0
var verbose = true

var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--load", "-l":
        index += 1
        if index < arguments.count, let value = Double(arguments[index]) {
            loadResistance = value
        }
    case "--quiet", "-q":
        verbose = false
    case "--help", "-h":
        print("""
        agpsu-sim — HP/Agilent 6632B power supply simulator

        Usage: agpsu-sim [--load OHMS] [--quiet]

          --load, -l   Simulated load resistance in ohms (default 10)
          --quiet, -q  Do not trace SCPI traffic

        Connect the app to the device path printed on start-up.
        """)
        exit(0)
    default:
        break
    }
    index += 1
}

let psu = SimulatedPSU()
psu.loadResistance = loadResistance

do {
    let server = try SimulatorServer(psu: psu)
    if verbose {
        server.onTraffic = { received, replied in
            let command = received.trimmingCharacters(in: .whitespacesAndNewlines)
            if let replied {
                print("  \(command)  ->  \(replied)")
            } else {
                print("  \(command)")
            }
        }
    }
    server.start()

    print("Simulated HP6632B ready.")
    print("  Device path : \(server.devicePath)")
    print("  Load        : \(loadResistance) ohm")
    print("  Settings    : 9600 8N1, no flow control")
    print("Press Ctrl-C to stop.")

    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("Failed to start simulator: \(error.localizedDescription)\n".utf8))
    exit(1)
}
