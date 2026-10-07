package cjdist

import std.collection.HashMap
import std.env.*
import std.fs.*
import std.process.*

class StartupResult {
    let success: Bool
    let timedOut: Bool
    let exitCode: Int64
    let stdout: String
    let stderr: String
    let error: String
    public init(exitCode: Int64, stdout: String, stderr: String) {
        success = true; timedOut = false; this.exitCode = exitCode
        this.stdout = stdout; this.stderr = stderr; error = ""
    }
    public init(timedOut: Bool, stdout: String, stderr: String, error: String) {
        success = false; this.timedOut = timedOut; exitCode = -1
        this.stdout = stdout; this.stderr = stderr; this.error = error
    }
}

// Runs directly (never via a shell) with a deliberately rebuilt PATH that has
// no SDK, SDK Runtime, or .cjpm\bin entries.
func runStartupProbe(root: Path, manifest: Manifest): StartupResult {
    let stdoutFile: File
    let stdoutPath: Path
    try { stdoutFile = File.createTemp(getTempDirectory()); stdoutPath = stdoutFile.info.path }
    catch (e: Exception) { return StartupResult(false, "", "", "unable to create stdout capture: ${e.message}") }
    let stderrFile: File
    let stderrPath: Path
    try { stderrFile = File.createTemp(getTempDirectory()); stderrPath = stderrFile.info.path }
    catch (e: Exception) { closeStartupFile(stdoutFile); removeStartupFile(stdoutPath); return StartupResult(false, "", "", "unable to create stderr capture: ${e.message}") }

    let systemRoot = match (getVariable("SystemRoot")) { case Some(value) => value; case None => "C:\\Windows" }
    let windowsDirectory = match (getVariable("WINDIR")) { case Some(value) => value; case None => systemRoot }
    let temp = match (getVariable("TEMP")) { case Some(value) => value; case None => getTempDirectory().toString() }
    let tmp = match (getVariable("TMP")) { case Some(value) => value; case None => temp }
    let path = root.toString() + ";" + Path(systemRoot).join("System32").toString() + ";" + windowsDirectory
    let environment = HashMap<String, String>([
        ("SystemRoot", systemRoot), ("WINDIR", windowsDirectory),
        ("TEMP", temp), ("TMP", tmp), ("PATH", path),
        ("PATHEXT", ".COM;.EXE;.BAT;.CMD"), ("OS", "Windows_NT")
    ])

    var timedOut = false
    var processError = ""
    var exitCode: Int64 = -1
    try {
        let child = launch(
            root.join(Path(manifest.entry)).normalize().toString(),
            manifest.verify.args,
            workingDirectory: root,
            environment: environment,
            stdOut: ProcessRedirect.FromFile(stdoutFile),
            stdErr: ProcessRedirect.FromFile(stderrFile)
        )
        try {
            exitCode = child.wait(timeout: Duration.millisecond * manifest.verify.timeoutMs)
        } catch (e: TimeoutException) {
            timedOut = true
            child.terminate(force: true)
            exitCode = child.wait()
        }
    } catch (e: Exception) {
        processError = "unable to launch or wait for startup probe: ${e.message}"
    }
    closeStartupFile(stdoutFile); closeStartupFile(stderrFile)
    var stdout = ""; var stderr = ""
    try { stdout = String.fromUtf8(File.readFrom(stdoutPath)); stderr = String.fromUtf8(File.readFrom(stderrPath)) }
    catch (e: Exception) { if (processError.isEmpty()) { processError = "unable to read startup output: ${e.message}" } }
    removeStartupFile(stdoutPath); removeStartupFile(stderrPath)
    if (!processError.isEmpty()) { return StartupResult(false, stdout, stderr, processError) }
    if (timedOut) { return StartupResult(true, stdout, stderr, "startup probe timed out after ${manifest.verify.timeoutMs} ms.") }
    return StartupResult(exitCode, stdout, stderr)
}

func reportStartupDiagnostics(result: StartupResult): Unit {
    let stdout = truncateDiagnostic(result.stdout)
    let stderr = truncateDiagnostic(result.stderr)
    if (!stdout.isEmpty()) { eprintln("Probe stdout:\n${stdout}") }
    if (!stderr.isEmpty()) { eprintln("Probe stderr:\n${stderr}") }
}

private func truncateDiagnostic(value: String): String {
    let limit: Int64 = 8192
    let bytes = value.toArray()
    if (bytes.size <= limit) { return value }
    var end = limit
    while (end > 0 && bytes[end] >= 128 && bytes[end] <= 191) { end-- }
    return String.fromUtf8(bytes[0..end]) + "\n(output truncated)"
}
private func closeStartupFile(file: File): Unit { try { if (!file.isClosed()) { file.close() } } catch (ignored: Exception) {} }
private func removeStartupFile(path: Path): Unit { try { removeIfExists(path) } catch (ignored: Exception) {} }
