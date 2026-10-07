package cjdist

import std.env.getVariable
import std.fs.*
import std.unicode.*

let SHA256_SCRIPT_CONTENT = "param([Parameter(Mandatory=$true)][string]$InputFile)\n" +
    "$ErrorActionPreference = 'Stop'\n" +
    "Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop\n" +
    "(Get-FileHash -LiteralPath $InputFile -Algorithm SHA256).Hash\n"

class Sha256Result {
    let success: Bool
    let hash: String
    let error: String

    public init(hash: String) {
        this.success = true
        this.hash = hash
        this.error = ""
    }

    public init(success: Bool, error: String) {
        this.success = success
        this.hash = ""
        this.error = error
    }
}

func resolveSystemPowerShell(): Sha256Result {
    let systemRoot = match (getVariable("SystemRoot")) {
        case Some(value) => value.trim()
        case None => return Sha256Result(false, "SystemRoot is not available; unable to locate Windows PowerShell.")
    }
    if (systemRoot.isEmpty()) {
        return Sha256Result(false, "SystemRoot is empty; unable to locate Windows PowerShell.")
    }
    let powershell = Path(systemRoot)
        .join("System32")
        .join("WindowsPowerShell")
        .join("v1.0")
        .join("powershell.exe")
        .normalize()
    try {
        let info = FileInfo(powershell)
        if (info.isSymbolicLink() || !info.isRegular()) {
            return Sha256Result(false, "System Windows PowerShell was not found at '${powershell}'.")
        }
    } catch (e: Exception) {
        return Sha256Result(false, "System Windows PowerShell was not found at '${powershell}'.")
    }
    return Sha256Result(powershell.toString())
}

func calculateFileSha256(powershellPath: String, scriptPath: Path, filePath: Path): Sha256Result {
    let command = runCaptured(
        powershellPath,
        [
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            scriptPath.toString(),
            "-InputFile",
            filePath.toString()
        ],
        filePath.parent
    )
    if (!command.success) {
        return Sha256Result(false, "Unable to run Windows PowerShell SHA-256: ${command.error}")
    }
    if (command.exitCode != 0) {
        let diagnostic = firstHashDiagnostic(command.stderr, command.stdout)
        let suffix = if (diagnostic.isEmpty()) { "" } else { " ${diagnostic}" }
        return Sha256Result(false, "PowerShell SHA-256 failed with exit code ${command.exitCode}.${suffix}")
    }
    if (!command.stderr.trim().isEmpty()) {
        return Sha256Result(false, "PowerShell SHA-256 wrote unexpected stderr output.")
    }
    return parseSha256Output(command.stdout)
}

func parseSha256Output(output: String): Sha256Result {
    let value = output.trim()
    let bytes = value.toArray()
    if (bytes.size != 64) {
        return Sha256Result(false, "PowerShell SHA-256 output is not exactly 64 hexadecimal characters.")
    }
    let normalized = Array<Byte>(64, repeat: 0)
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        let isDigit = byte >= 48 && byte <= 57
        let isLower = byte >= 97 && byte <= 102
        let isUpper = byte >= 65 && byte <= 70
        if (!isDigit && !isLower && !isUpper) {
            return Sha256Result(false, "PowerShell SHA-256 output contains a non-hexadecimal character.")
        }
        normalized[index] = if (isUpper) { byte + 32 } else { byte }
    }
    return Sha256Result(String.fromUtf8(normalized))
}

private func firstHashDiagnostic(primary: String, secondary: String): String {
    for (source in [primary, secondary]) {
        for (rawLine in source.lines()) {
            let line = rawLine.trim()
            if (!line.isEmpty()) {
                return line
            }
        }
    }
    return ""
}
