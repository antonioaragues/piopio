import Darwin
import Foundation

// piopio-engine: starts the engine bundled in Piopio.app (Contents/Helpers/node on Contents/Resources/engine/main.js).
// The app runs it as a child process; in background mode launchd runs it from the LaunchAgent, which can only name
// programs by their path inside the bundle. Output goes to <PIOPIO_HOME>/logs/engine.log.

var size: UInt32 = 0
_ = _NSGetExecutablePath(nil, &size)
var buffer = [CChar](repeating: 0, count: Int(size))
_ = _NSGetExecutablePath(&buffer, &size)
let contents = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent()
let node = contents.appending(path: "Helpers/node").path
let main = contents.appending(path: "Resources/engine/main.js").path

let env = ProcessInfo.processInfo.environment
let home = env["PIOPIO_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Piopio").path
try? FileManager.default.createDirectory(atPath: "\(home)/logs", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
setenv("PIOPIO_HOME", home, 1)
let log = open("\(home)/logs/engine.log", O_WRONLY | O_CREAT | O_APPEND, 0o600)
if log >= 0 {
    dup2(log, STDOUT_FILENO)
    dup2(log, STDERR_FILENO)
    close(log)
}

let args = [node, main] + CommandLine.arguments.dropFirst()
var argv = args.map { strdup($0) } + [nil]
execv(node, &argv)
FileHandle.standardError.write(Data("piopio-engine: cannot run \(node): \(String(cString: strerror(errno)))\n".utf8))
exit(1)
