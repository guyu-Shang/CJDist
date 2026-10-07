package cjdist

import std.env.getTempDirectory
import std.fs.*
import std.process.*

class CapturedProcessResult {
    let success: Bool
    let exitCode: Int64
    let stdout: String
    let stderr: String
    let error: String

    public init(exitCode: Int64, stdout: String, stderr: String) {
        this.success = true
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.error = ""
    }

    public init(error: String) {
        this.success = false
        this.exitCode = -1
        this.stdout = ""
        this.stderr = ""
        this.error = error
    }
}

// File-backed redirection avoids the bounded-pipe deadlock that can occur when a
// child writes heavily to stdout and stderr while the parent waits for exit.
func runCaptured(command: String, arguments: Array<String>, workingDirectory: Path): CapturedProcessResult {
    let stdoutFile: File
    let stdoutPath: Path
    try {
        stdoutFile = File.createTemp(getTempDirectory())
        stdoutPath = stdoutFile.info.path
    } catch (e: Exception) {
        return CapturedProcessResult("unable to create a stdout capture file: ${e.message}")
    }

    let stderrFile: File
    let stderrPath: Path
    try {
        stderrFile = File.createTemp(getTempDirectory())
        stderrPath = stderrFile.info.path
    } catch (e: Exception) {
        closeQuietly(stdoutFile)
        removeQuietly(stdoutPath)
        return CapturedProcessResult("unable to create a stderr capture file: ${e.message}")
    }

    let exitCode: Int64
    try {
        exitCode = execute(
            command,
            arguments,
            workingDirectory: Some(workingDirectory),
            stdOut: ProcessRedirect.FromFile(stdoutFile),
            stdErr: ProcessRedirect.FromFile(stderrFile)
        )
    } catch (e: Exception) {
        closeQuietly(stdoutFile)
        closeQuietly(stderrFile)
        removeQuietly(stdoutPath)
        removeQuietly(stderrPath)
        return CapturedProcessResult("unable to launch '${command}': ${e.message}")
    }

    closeQuietly(stdoutFile)
    closeQuietly(stderrFile)

    let stdout: String
    let stderr: String
    try {
        stdout = String.fromUtf8(File.readFrom(stdoutPath))
        stderr = String.fromUtf8(File.readFrom(stderrPath))
    } catch (e: Exception) {
        removeQuietly(stdoutPath)
        removeQuietly(stderrPath)
        return CapturedProcessResult("unable to read captured process output: ${e.message}")
    }

    removeQuietly(stdoutPath)
    removeQuietly(stderrPath)
    return CapturedProcessResult(exitCode, stdout, stderr)
}

func replayProcessOutput(result: CapturedProcessResult): Unit {
    if (!result.stdout.isEmpty()) {
        print(result.stdout, flush: true)
    }
    if (!result.stderr.isEmpty()) {
        eprint(result.stderr, flush: true)
    }
}

private func closeQuietly(file: File): Unit {
    try {
        if (!file.isClosed()) {
            file.close()
        }
    } catch (e: Exception) {
        // A later read or removal reports the actionable failure.
    }
}

private func removeQuietly(path: Path): Unit {
    try {
        removeIfExists(path)
    } catch (e: Exception) {
        // Capture cleanup is best-effort and must not hide the child result.
    }
}
