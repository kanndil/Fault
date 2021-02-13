import Foundation
import Defile

extension String {
    func shOutput() -> (terminationStatus: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["sh", "-c", self]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
        } catch {
            Stderr.print("Could not launch task `\(self)': \(error)")
            exit(EX_UNAVAILABLE)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        task.waitUntilExit()

        let output = String(data: data, encoding: .utf8)

        return (terminationStatus: task.terminationStatus, output: output!)
    }

    func sh() -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["sh", "-c", self]

        do {
            try task.run()
        } catch {
            Stderr.print("Could not launch task `\(self)': \(error)")
            exit(EX_UNAVAILABLE)
        }

        task.waitUntilExit()

        return task.terminationStatus
    }

    func uniqueName(_ number: Int) -> String {
        return "__" + self + "_" + String(describing: number) + "__"
    }
}

extension String: Error {}

extension Encodable {
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(self)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

extension String {
    static var boilerplate: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = Date()
        let dateString = dateFormatter.string(from: date)

        return  """
        /*
            Automatically generated by Fault
            Do not modify.
            Generated on: \(dateString)
        */
        """;
    }
}