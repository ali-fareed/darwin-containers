import Foundation

@MainActor
func installSshCredentials(ipAddress: String, privateKey: String, publicKey: String, verbose: Bool) async throws {
    let tempDirectory = FileManager.default.temporaryDirectory.path
    let expectScriptPath = tempDirectory + "/\(UUID())"
    
    let expectScript = """
#!/usr/bin/expect -f
set username [lindex $argv 0]
set host [lindex $argv 1]
set password [lindex $argv 2]
set public_key [lindex $argv 3]

spawn ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=60 $username@$host
expect "* Password:"
send "$password\r"
expect "* ~ % "
send "mkdir -p ~/.ssh && echo $public_key > ~/.ssh/authorized_keys && echo done\r"
expect "done"
send "exit\r"
"""
    try expectScript.write(toFile: expectScriptPath, atomically: true, encoding: .utf8)
    
    if verbose {
        print("Copying ssh credentials to \(ipAddress)...")
    }
    
    let _ = try shell(
        executable: "/usr/bin/expect",
        arguments: [
            "-f",
            expectScriptPath,
            "containerhost",
            ipAddress,
            "containerhost",
            publicKey
        ]
    )
    
    //let privateKeyPath = tempDirectory + "/\(UUID())"
    //try privateKey.data(using: .utf8)!.write(to: URL(fileURLWithPath: privateKeyPath))
    //let _ = shell("chmod 600 \"\(privateKeyPath)\"")
    
    try FileManager.default.removeItem(atPath: expectScriptPath)
}
