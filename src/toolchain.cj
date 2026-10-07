package cjdist

import std.env.getVariable
import std.env.getWorkingDirectory
import std.fs.*
import std.unicode.*

class ToolchainInfo {
    let sdkRoot: String
    let cjpmPath: String
    let cjcPath: String
    let cjpmVersion: String
    let cjcVersion: String
    let target: String

    public init(
        sdkRoot: String,
        cjpmPath: String,
        cjcPath: String,
        cjpmVersion: String,
        cjcVersion: String,
        target: String
    ) {
        this.sdkRoot = sdkRoot
        this.cjpmPath = cjpmPath
        this.cjcPath = cjcPath
        this.cjpmVersion = cjpmVersion
        this.cjcVersion = cjcVersion
        this.target = target
    }
}

class ToolchainResult {
    let success: Bool
    let info: ?ToolchainInfo
    let error: String

    public init(info: ToolchainInfo) {
        this.success = true
        this.info = Some(info)
        this.error = ""
    }

    public init(error: String) {
        this.success = false
        this.info = None
        this.error = error
    }
}

private class CompilerVersionResult {
    let success: Bool
    let version: String
    let target: String
    let error: String

    public init(version: String, target: String) {
        this.success = true
        this.version = version
        this.target = target
        this.error = ""
    }

    public init(error: String) {
        this.success = false
        this.version = ""
        this.target = ""
        this.error = error
    }
}

func resolveToolchain(): ToolchainResult {
    let pathValue = match (getVariable("PATH")) {
        case Some(value) => value
        case None => return ToolchainResult("cjpm.exe was not found in the current PATH.")
    }

    let cjpmPath = findFirstCjpm(pathValue)
    if (cjpmPath.isEmpty()) {
        return ToolchainResult("cjpm.exe was not found in the current PATH.")
    }

    let cjpm = Path(cjpmPath)
    let binDirectory = cjpm.parent
    let toolsDirectory = binDirectory.parent
    let sdkRoot = toolsDirectory.parent
    if (
        !asciiEqualsIgnoreCase(cjpm.fileName, "cjpm.exe") ||
        !asciiEqualsIgnoreCase(binDirectory.fileName, "bin") ||
        !asciiEqualsIgnoreCase(toolsDirectory.fileName, "tools") ||
        sdkRoot.isEmpty()
    ) {
        return ToolchainResult("Unable to derive a Cangjie SDK root from cjpm.exe.")
    }

    let cjc = sdkRoot.join("bin").join("cjc.exe").normalize()
    try {
        if (!FileInfo(cjc).isRegular()) {
            return ToolchainResult("The selected Cangjie SDK does not contain bin\\cjc.exe.")
        }
    } catch (e: Exception) {
        return ToolchainResult("The selected Cangjie SDK does not contain bin\\cjc.exe.")
    }

    let cjpmCommand = runCaptured(cjpm.toString(), ["--version"], sdkRoot)
    if (!cjpmCommand.success) {
        return ToolchainResult("Unable to query cjpm version: ${cjpmCommand.error}")
    }
    if (cjpmCommand.exitCode != 0) {
        return ToolchainResult("cjpm --version failed with exit code ${cjpmCommand.exitCode}.")
    }
    let cjpmVersion = parseCjpmVersion(cjpmCommand.stdout + "\n" + cjpmCommand.stderr)
    if (cjpmVersion.isEmpty()) {
        return ToolchainResult("Unable to parse cjpm --version output.")
    }

    let cjcCommand = runCaptured(cjc.toString(), ["--version"], sdkRoot)
    if (!cjcCommand.success) {
        return ToolchainResult("Unable to query cjc version: ${cjcCommand.error}")
    }
    if (cjcCommand.exitCode != 0) {
        return ToolchainResult("cjc --version failed with exit code ${cjcCommand.exitCode}.")
    }
    let compiler = parseCompilerVersion(cjcCommand.stdout + "\n" + cjcCommand.stderr)
    if (!compiler.success) {
        return ToolchainResult(compiler.error)
    }
    if (compiler.target != "x86_64-w64-mingw32") {
        return ToolchainResult("Unsupported target '${compiler.target}'; CJDist v0.1 requires x86_64-w64-mingw32.")
    }

    return ToolchainResult(
        ToolchainInfo(
            sdkRoot.toString(),
            cjpm.toString(),
            cjc.toString(),
            cjpmVersion,
            compiler.version,
            compiler.target
        )
    )
}

private func findFirstCjpm(pathValue: String): String {
    for (rawEntry in pathValue.split(Path.ListSeparator)) {
        let entry = removeOuterQuotes(rawEntry.trim())
        if (entry.isEmpty()) {
            continue
        }

        try {
            let rawDirectory = Path(entry)
            let directory = if (rawDirectory.isAbsolute()) {
                rawDirectory.normalize()
            } else {
                getWorkingDirectory().join(rawDirectory).normalize()
            }
            let candidate = directory.join("cjpm.exe").normalize()
            if (FileInfo(candidate).isRegular()) {
                return candidate.toString()
            }
        } catch (e: Exception) {
            // Invalid or inaccessible PATH entries do not shadow later entries.
        }
    }
    return ""
}

private func removeOuterQuotes(value: String): String {
    if (value.size >= 2 && value.startsWith("\"") && value.endsWith("\"")) {
        return value[1..(value.size - 1)].trim()
    }
    return value
}

private func parseCjpmVersion(output: String): String {
    for (rawLine in output.lines()) {
        let line = rawLine.trim()
        for (prefix in ["Cangjie Package Manager:", "Cangjie Project Manager:"]) {
            if (line.startsWith(prefix)) {
                return parseVersionToken(line[prefix.size..line.size].trim())
            }
        }
    }
    return ""
}

private func parseCompilerVersion(output: String): CompilerVersionResult {
    var version = ""
    var target = ""
    for (rawLine in output.lines()) {
        let line = rawLine.trim()
        let compilerPrefix = "Cangjie Compiler:"
        let targetPrefix = "Target:"
        if (line.startsWith(compilerPrefix)) {
            version = parseVersionToken(line[compilerPrefix.size..line.size].trim())
        } else if (line.startsWith(targetPrefix)) {
            let candidate = line[targetPrefix.size..line.size].trim()
            if (!candidate.isEmpty() && !containsAsciiWhitespace(candidate)) {
                target = candidate
            }
        }
    }
    if (version.isEmpty()) {
        return CompilerVersionResult("Unable to parse the compiler version from cjc --version output.")
    }
    if (target.isEmpty()) {
        return CompilerVersionResult("Unable to parse the target from cjc --version output.")
    }
    return CompilerVersionResult(version, target)
}

private func parseVersionToken(value: String): String {
    let tokens = value.split(" ", removeEmpty: true)
    if (tokens.size == 0) {
        return ""
    }
    let token = tokens[0]
    let bytes = token.toArray()
    if (bytes.size == 0 || bytes[0] < 48 || bytes[0] > 57) {
        return ""
    }
    for (byte in bytes) {
        let isDigit = byte >= 48 && byte <= 57
        let isLower = byte >= 97 && byte <= 122
        let isUpper = byte >= 65 && byte <= 90
        if (!isDigit && !isLower && !isUpper && byte != 46 && byte != 45 && byte != 43) {
            return ""
        }
    }
    return token
}

private func containsAsciiWhitespace(value: String): Bool {
    for (byte in value.toArray()) {
        if (byte == 32 || byte == 9 || byte == 10 || byte == 13) {
            return true
        }
    }
    return false
}

private func asciiEqualsIgnoreCase(left: String, right: String): Bool {
    let leftBytes = left.toArray()
    let rightBytes = right.toArray()
    if (leftBytes.size != rightBytes.size) {
        return false
    }
    for (index in 0..leftBytes.size) {
        if (asciiLowerByte(leftBytes[index]) != asciiLowerByte(rightBytes[index])) {
            return false
        }
    }
    return true
}

private func asciiLowerByte(value: Byte): Byte {
    if (value >= 65 && value <= 90) {
        return value + 32
    }
    return value
}
