import class Foundation.Bundle
import XCTest

var env = ProcessInfo.processInfo.environment

extension Process {
    func startAndBlock() throws {
        log("$ \(executableURL!.path) \((arguments ?? []).joined(separator: " "))")
        launch()
        waitUntilExit()
        print("Exited with: \(terminationStatus)")
    }
}

extension String {
    func shOutput() -> (terminationStatus: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["sh", "-c", self]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            print("Could not launch task `\(self)': \(error)")
            exit(EX_UNAVAILABLE)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8)

        return (terminationStatus: task.terminationStatus, output: output!)
    }
}

func log(_ string: String) {
    print(string)
    fflush(stdout)
}

final class FaultTests: XCTestCase {
    func run(scl: String, steps: [[String]]) throws {
        let binary = productsDirectory.appendingPathComponent("Fault")
        for (i, step) in steps.enumerated() {
            log("\(scl): \(i)/6")
            let process = Process()
            process.executableURL = binary
            process.arguments = step
            try process.startAndBlock()

            XCTAssertEqual(process.terminationStatus, 0)
            if process.terminationStatus != 0 {
                return
            }
        }
    }

    func testSPM() throws {
        /*
             This test runs the default SPM design, which is an all-digital
             active-low design.
         */

        // Fault Tests
        for (scl, liberty, models, config) in [
            ("osu035", "Tech/osu035/osu035_stdcells.lib", "Tech/osu035/osu035_stdcells.v", "Tech/osu035/config.yml"),
            // ("sky130_fd_sc_hd", "Tech/sky130_fd_sc_hd/sky130_fd_sc_hd__trimmed.lib", "Tech/sky130_fd_sc_hd/sky130_fd_sc_hd.v", "Tech/sky130_fd_sc_hd/config.yml"),
        ] {
            let fileName = "Tests/RTL/spm/spm.v"
            let topModule = "spm"
            let clock = "clk"
            let reset = "rst"
            let ignoredInputs = "\(reset)"

            let base = "Netlists/" + NSString(string: fileName).deletingPathExtension
            let fileSynth = base + ".nl.v"
            let fileCut = base + ".cut.v"
            let fileJson = base + ".tv.json"
            let fileChained = base + ".chained.v"
            let fileAsmVec = fileJson + ".vec.bin"
            let fileAsmOut = fileJson + ".out.bin"

            let fileManager = FileManager()
            for file in [fileSynth, fileCut, fileJson, fileChained, fileAsmVec, fileAsmOut] {
                try? fileManager.removeItem(atPath: file)
            }

            try run(scl: scl, steps: [
                ["synth", "-l", liberty, "-t", topModule, "-o", fileSynth, fileName],
                ["cut", "-o", fileCut, "--sclConfig", config, fileSynth],
                ["-c", models, "-i", ignoredInputs, "--clock", clock, "-o", fileJson, fileCut],
                ["chain", "-c", models, "-l", liberty, "-o", fileChained, "--clock", clock, "--reset", reset, "--activeLow", "-i", ignoredInputs, "--sclConfig", config, fileSynth],
                ["asm", fileJson, fileChained],
                ["compact", "-o", "/dev/null", fileJson],
                ["tap", fileChained, "-c", models, "--clock", clock, "--reset", reset, "--activeLow", "-l", liberty, "-t", fileAsmVec, "-g", fileAsmOut, "-i", ignoredInputs],
            ])
            
        }
    }

    func testIntegration() throws {
        /*
             This test runs the TripleDelay design, which has blackboxed macros.
         */

        // Fault Tests
        let liberty = "Tech/osu035/osu035_stdcells.lib"
        let models = "Tech/osu035/osu035_stdcells.v"

        let fileName = "Tests/RTL/integration/triple_delay.v"
        let topModule = "TripleDelay"
        let clock = "clk"
        let reset = "rst"
        let ignoredInputs = "\(reset),rstn"

        let base = "Netlists/" + NSString(string: fileName).deletingPathExtension
        let fileSynth = base + ".nl.v"
        let fileCut = base + ".cut.v"
        let fileJson = base + ".tv.json"
        let faultPointsYML = base + ".fault_points.yml"
        let coverageYml = base + ".coverage_meta.yml"
        let fileChained = base + ".chained.v"
        let fileAsmVec = fileJson + ".vec.bin"
        let fileAsmOut = fileJson + ".out.bin"

        let fileManager = FileManager()
        for file in [fileSynth, fileCut, fileJson, fileChained, fileAsmVec, fileAsmOut] {
            try? fileManager.removeItem(atPath: file)
        }

        try run(scl: "osu035", steps: [
            ["synth", "-l", liberty, "-t", topModule, "-o", fileSynth, "--blackboxModel", "Tests/RTL/integration/buffered_inverter.v", fileName],
            ["cut", "-o", fileCut, "--blackbox", "BufferedInverter", "--blackboxModel", "Tests/RTL/integration/buffered_inverter.v", "--ignoring", "clk,rst,rstn", fileSynth],
            ["-c", models, "-i", reset, "--clock", clock, "-o", fileJson, "--output-faultPoints", faultPointsYML, "--output-covered", coverageYml, fileCut],
            ["chain", "-c", models, "-l", liberty, "-o", fileChained, "--clock", clock, "--reset", reset, "--activeLow", "-i", ignoredInputs, fileSynth, "--blackbox", "BufferedInverter", "--blackboxModel", "Tests/RTL/integration/buffered_inverter.v"],
            ["asm", fileJson, fileChained],
            ["compact", "-o", "/dev/null", fileJson],
            ["tap", fileChained, "-c", models, "--clock", clock, "--reset", reset, "--active-low", "-l", liberty, "-t", fileAsmVec, "-g", fileAsmOut, "--blackboxModel", "Tests/RTL/integration/buffered_inverter.v"],
        ])
    }

    /// Returns path to the built products directory.
    var productsDirectory: URL {
        #if os(macOS)
            for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
                return bundle.bundleURL.deletingLastPathComponent()
            }
            fatalError("couldn't find the products directory")
        #else
            return Bundle.main.bundleURL
        #endif
    }

    static var allTests = [
        ("testSPM", testSPM),
        ("testIntegration", testIntegration),
    ]
}
