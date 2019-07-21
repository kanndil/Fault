import Foundation
import Defile
import PythonKit

let TempDir = Python.import("tempfile")

class Simulator {
    enum Behavior {
        case holdHigh
        case holdLow
    }

    private static func pseudoRandomVerilogGeneration(
        using testVector: TestVector,
        for faultPoints: Set<String>,
        in file: String,
        module: String,
        with cells: String, 
        ports: [String: Port],
        inputs: [Port],
        ignoring ignoredInputs: Set<String>,
        behavior: [Behavior],
        outputs: [Port],
        stuckAt: Int,
        cleanUp: Bool,
        filePrefix: String = "."
    ) throws -> [String] {
        var portWires = ""
        var portHooks = ""
        var portHooksGM = ""

        for (rawName, port) in ports {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name) ;\n"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name).gm ;\n"
            portHooks += ".\(name) ( \(name) ) , "
            portHooksGM += ".\(name) ( \(name).gm ) , "
        }

        let folderName = "\(filePrefix)/thr\(Unmanaged.passUnretained(Thread.current).toOpaque())"
        let _ = "mkdir -p \(folderName)".sh()

        var inputAssignment = ""
        var fmtString = ""
        var inputList = ""

        for (i, input) in inputs.enumerated() {
            let name = (input.name.hasPrefix("\\")) ? input.name : "\\\(input.name)"

            inputAssignment += "        \(name) = \(testVector[i]) ;\n"
            inputAssignment += "        \(name).gm = \(name) ;\n"

            fmtString += "%d "
            inputList += "\(name) , "
        }

        for rawName in ignoredInputs {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"

            inputAssignment += "        \(name) = 0 ;\n"
            inputAssignment += "        \(name).gm = 0 ;\n"
        }

        fmtString = String(fmtString.dropLast(1))
        inputList = String(inputList.dropLast(2))

        var outputComparison = ""
        for output in outputs {
            let name = (output.name.hasPrefix("\\")) ? output.name : "\\\(output.name)"
            outputComparison += " ( \(name) != \(name).gm ) || "
        }
        outputComparison = String(outputComparison.dropLast(3))

        var faultForces = ""
        for fault in faultPoints {
            faultForces += "        force uut.\(fault) = \(stuckAt) ; \n"   
            faultForces += "        if (difference) $display(\"\(fault)\") ; \n"
            faultForces += "        #1 ; \n"
            faultForces += "        release uut.\(fault) ;\n"
        }

        let bench = """
        \(String.boilerplate)

        `include "\(cells)"
        `include "\(file)"

        module FaultTestbench;

        \(portWires)

            \(module) uut(
                \(portHooks.dropLast(2))
            );
            \(module) gm(
                \(portHooksGM.dropLast(2))
            );

            wire difference ;
            assign difference = (\(outputComparison));

            integer counter;

            initial begin
        \(inputAssignment)
        \(faultForces)
                $finish;
            end

        endmodule
        """;

        let tbName = "\(folderName)/tb.sv"
        try File.open(tbName, mode: .write) {
            try $0.print(bench)
        }

        let aoutName = "\(folderName)/a.out"

        let iverilogResult =
            "iverilog -Ttyp -o \(aoutName) \(tbName) 2>&1 > /dev/null".sh()
        if iverilogResult != EX_OK {
            exit(Int32(iverilogResult))
        }

        let vvpTask = "vvp \(aoutName)".shOutput()

        if vvpTask.terminationStatus != EX_OK {
            exit(vvpTask.terminationStatus)
        }

        if cleanUp {
            let _ = "rm -rf \(folderName)".sh()
        }

        return vvpTask.output.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static func simulate(
        for faultPoints: Set<String>,
        in file: String,
        module: String,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        ignoring ignoredInputs: Set<String> = [],
        behavior: [Behavior] = [],
        outputs: [Port],
        tvAttempts: Int,
        sampleRun: Bool
    ) throws -> (coverageList: [TVCPair], coverage: Float) {

        var futureList: [Future<Coverage>] = []
        
        var testVectorHash: Set<TestVector> = []
        var testVectors: [TestVector] = []

        for _ in 0..<tvAttempts {
            var testVector: TestVector = []
            for input in inputs {
                let max: UInt = (1 << UInt(input.width)) - 1
                testVector.append(
                    UInt.random(in: 0...max)
                )
            }
            if testVectorHash.contains(testVector) {
                continue
            }
            testVectorHash.insert(testVector)
            testVectors.append(testVector)
        }

        if testVectors.count < tvAttempts {
            print("Skipped \(tvAttempts - testVectors.count) duplicate generated test vectors.")
        }

        let tempDir = "\(TempDir.gettempdir())"

        for vector in testVectors {
            let future = Future<Coverage> {
                do {
                    let sa0 =
                        try Simulator.pseudoRandomVerilogGeneration(
                            using: vector,
                            for: faultPoints,
                            in: file,
                            module: module,
                            with: cells,
                            ports: ports,
                            inputs: inputs,
                            ignoring: ignoredInputs,
                            behavior: behavior,
                            outputs: outputs,
                            stuckAt: 0,
                            cleanUp: !sampleRun,
                            filePrefix: tempDir
                        )

                    let sa1 =
                        try Simulator.pseudoRandomVerilogGeneration(
                            using: vector,
                            for: faultPoints,
                            in: file,
                            module: module,
                            with: cells,
                            ports: ports,
                            inputs: inputs,
                            ignoring: ignoredInputs,
                            behavior: behavior,
                            outputs: outputs,
                            stuckAt: 1,
                            cleanUp: !sampleRun,
                            filePrefix: tempDir
                        )

                    return Coverage(sa0: sa0, sa1: sa1)
                } catch {
                    print("IO Error @ vector \(vector)")
                    return Coverage(sa0: [], sa1: [])

                }
            }
            futureList.append(future)
            if sampleRun {
                break
            }
        }

        var sa0Covered: Set<String> = []
        sa0Covered.reserveCapacity(faultPoints.count)
        var sa1Covered: Set<String> = []
        sa1Covered.reserveCapacity(faultPoints.count)
        var coverageList: [TVCPair] = []

        for (i, future) in futureList.enumerated() {
            let coverLists = future.value
            for cover in coverLists.sa0 {
                sa0Covered.insert(cover)
            }
            for cover in coverLists.sa1 {
                sa1Covered.insert(cover)
            }
            coverageList.append(
                TVCPair(vector: testVectors[i], coverage: coverLists)
            )
        }

        return (
            coverageList: coverageList,
            coverage:
                Float(sa0Covered.count + sa1Covered.count) /
                Float(2 * faultPoints.count)
        )
    }

    enum Active {
        case low
        case high
    }

    static func simulate(
        verifying module: String,
        in file: String,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        outputs: [Port],
        dffCount: Int,
        rstBar: String,
        shiftBR: String,
        clockBR: String,
        and clock: String? = nil,
        updateBR: String,
        modeControl: String,
        reset: String? = nil,
        active: Active = .low
    ) throws -> Bool {
        let tempDir = "\(TempDir.gettempdir())"
        let folderName = "\(tempDir)/thr\(Unmanaged.passUnretained(Thread.current).toOpaque())"
        let _ = "mkdir -p '\(folderName)'".sh()
        defer {
            let _ = "rm -rf '\(folderName)'".sh()
        }

        let managedSignals: [String: String] = [
            rstBar: "rstBar",
            shiftBR: "shiftBR",
            clockBR: "clockBR",
            updateBR: "updateBR",
            modeControl: "modeControl"
        ]

        var portWires = ""
        var portHooks = ""
        for (rawName, port) in ports {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"
            if let managedSignal = managedSignals[name] {
                portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(managedSignal) ;\n"
                portHooks += ".\(name) ( \(managedSignal) ) , "
            } else {
                if let clockSignal = clock, rawName == clockSignal {
                    portWires += "    wire[\(port.from):\(port.to)] \(name) ;\n"
                } else if let resetSignal = reset, rawName == resetSignal {
                    portWires += "    wire[\(port.from):\(port.to)] \(name) ;\n"
                } else {
                    portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name) ;\n"
                }
                portHooks += ".\(name) ( \(name) ) , "
            }
        }

        var inputAssignment = ""
        for input in inputs {
            var name = (input.name.hasPrefix("\\")) ? input.name : "\\\(input.name)"
            if let managedSignal = managedSignals[name] {
                name = managedSignal
            }
            if let clockSignal = clock, input.name == clockSignal {
            } else if let resetSignal = reset, input.name == resetSignal {
            } else {
                inputAssignment += "        \(name) = 0 ;\n"
            }
        }

        var resetAssignment = ""
        if let resetSignal = reset {
            if active == .high {
                resetAssignment = "assign \(resetSignal) = ~rstBar ;"
            } else {
                resetAssignment = "assign \(resetSignal) = rstBar ;"
            }
        }

        var clockAssignment = ""
        if let clockSignal = clock {
            clockAssignment = "assign \(clockSignal) = clockBR;"
        }

        var serial = ""
        for _ in 0..<dffCount {
            serial += "\(Int.random(in: 0...1))"
        }

        let bench = """
        \(String.boilerplate)
        `include "\(cells)"
        `include "\(file)"

        module testbench;
            \(portWires)

            \(clockAssignment)
            \(resetAssignment)

            always #1 clockBR = ~clockBR;

            \(module) uut(
                \(portHooks.dropLast(2))
            );

            wire[\(dffCount - 1):0] serializable =
                \(dffCount)'b\(serial);
            reg[\(dffCount - 1):0] serial;
            integer i;

            initial begin
            \(inputAssignment)
                #10;
                rstBar = 1;
                shift = 1;
                for (i = 0; i < \(dffCount); i = i + 1) begin
                    sin = serializable[i];
                    #2;
                end
                for (i = 0; i < \(dffCount); i = i + 1) begin
                    serial[i] = sout;
                    #2;
                end
                if (serial == serializable) begin
                    $display("SUCCESS_STRING");
                end
                $finish;
            end
        endmodule
        """

        let tbName = "\(folderName)/tb.sv"
        try File.open(tbName, mode: .write) {
            try $0.print(bench)
        }

        let aoutName = "\(folderName)/a.out"

        let iverilogResult =
            "iverilog -Ttyp -o \(aoutName) \(tbName) 2>&1 > /dev/null".sh()
        if iverilogResult != EX_OK {
            exit(Int32(iverilogResult))
        }

        let vvpTask = "vvp \(aoutName)".shOutput()

        if vvpTask.terminationStatus != EX_OK {
            throw "Failed to run vvp."
        }

        return vvpTask.output.contains("SUCCESS_STRING")
    }
}