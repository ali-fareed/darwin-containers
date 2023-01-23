import Foundation

struct ShellException: Error {
    var output: String
}

func shell(_ command: String) -> String {
    let task = Process()
    let pipe = Pipe()
    
    task.standardOutput = pipe
    task.standardError = pipe
    task.arguments = ["-c", command]
    task.launchPath = "/bin/zsh"
    task.launch()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)!
    
    return output
}

func shell(executable: String, arguments: [String]) throws -> String {
    print("\(executable) \(arguments.joined(separator: " "))")
    
    let task = Process()
    let pipe = Pipe()
    
    task.standardOutput = pipe
    task.standardError = pipe
    task.arguments = arguments
    task.launchPath = executable
    
    try task.run()
    
    task.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)!
    
    if task.terminationStatus != 0 {
        throw ShellException(output: output)
    } else {
        return output
    }
}
