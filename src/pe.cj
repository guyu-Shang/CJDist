package cjdist

import std.collection.ArrayList
import std.fs.*
import std.unicode.*

class PeAnalysis {
    let imports: Array<String>

    public init(imports: Array<String>) {
        this.imports = imports
    }
}

class PeAnalysisResult {
    let success: Bool
    let analysis: ?PeAnalysis
    let error: String

    public init(analysis: PeAnalysis) {
        this.success = true
        this.analysis = Some(analysis)
        this.error = ""
    }

    public init(error: String) {
        this.success = false
        this.analysis = None
        this.error = error
    }
}

// This inspects the static PE import table only. It cannot discover DLLs loaded
// through LoadLibrary, plug-in/configuration mechanisms, or other dynamic paths.
func analyzePeImports(filePath: Path, toolchain: ToolchainInfo): PeAnalysisResult {
    let objdump = Path(toolchain.sdkRoot)
        .join("third_party")
        .join("llvm")
        .join("bin")
        .join("llvm-objdump.exe")
        .normalize()
    try {
        if (!FileInfo(objdump).isRegular()) {
            return PeAnalysisResult("The selected SDK does not contain third_party\\llvm\\bin\\llvm-objdump.exe.")
        }
        if (!FileInfo(filePath).isRegular()) {
            return PeAnalysisResult("PE input is not a regular file: ${filePath}")
        }
    } catch (e: Exception) {
        return PeAnalysisResult("Unable to access the PE analyzer or input file: ${e.message}")
    }

    let command = runCaptured(objdump.toString(), ["-p", filePath.toString()], filePath.parent)
    if (!command.success) {
        return PeAnalysisResult("Unable to run same-SDK llvm-objdump: ${command.error}")
    }
    if (command.exitCode != 0) {
        let diagnostic = firstNonEmptyLine(command.stderr, command.stdout)
        let suffix = if (diagnostic.isEmpty()) { "" } else { " ${diagnostic}" }
        return PeAnalysisResult("llvm-objdump failed with exit code ${command.exitCode}.${suffix}")
    }
    return parsePeImports(command.stdout)
}

// llvm-objdump 1.0.5 prints import descriptors between these top-level
// sections. Requiring both boundaries prevents an Export Table `DLL name:`
// line from being misidentified as a static import.
func parsePeImports(output: String): PeAnalysisResult {
    let imports = ArrayList<String>()
    var inImportTable = false
    var foundImportTable = false
    var foundEndBoundary = false

    for (rawLine in output.lines()) {
        let line = rawLine.trim()
        if (line == "The Import Tables:") {
            if (foundImportTable) {
                return PeAnalysisResult("Malformed llvm-objdump output: duplicate Import Tables section.")
            }
            if (rawLine != line) {
                return PeAnalysisResult("Malformed llvm-objdump output: indented Import Tables heading.")
            }
            foundImportTable = true
            inImportTable = true
            continue
        }
        if (!inImportTable) {
            continue
        }

        // The next unindented section heading is the reliable end boundary.
        if (rawLine == line && !line.isEmpty() && line.endsWith(":")) {
            foundEndBoundary = true
            inImportTable = false
            continue
        }

        if (line.startsWith("DLL Name:")) {
            if (rawLine == line) {
                return PeAnalysisResult("Malformed llvm-objdump output: unindented import descriptor.")
            }
            let name = line["DLL Name:".size..line.size].trim()
            let nameError = validateImportedName(name)
            if (!nameError.isEmpty()) {
                return PeAnalysisResult("Malformed llvm-objdump import descriptor: ${nameError}")
            }
            if (!containsAsciiIgnoreCase(imports, name)) {
                imports.add(name)
            }
        } else if (startsWithAsciiIgnoreCase(line, "DLL Name")) {
            return PeAnalysisResult("Malformed llvm-objdump import descriptor line.")
        }
    }

    if (!foundImportTable) {
        return PeAnalysisResult("Unable to confirm an llvm-objdump Import Tables section.")
    }
    if (!foundEndBoundary) {
        return PeAnalysisResult("Unable to confirm the end of the llvm-objdump Import Tables section.")
    }
    if (imports.size == 0) {
        return PeAnalysisResult("The confirmed llvm-objdump Import Tables section contains no DLL descriptors.")
    }
    return PeAnalysisResult(PeAnalysis(imports.toArray()))
}

private func validateImportedName(name: String): String {
    if (name.isEmpty()) {
        return "empty DLL name"
    }
    if (name == "." || name == "..") {
        return "invalid DLL name '${name}'"
    }
    for (byte in name.toArray()) {
        if (byte < 32 || byte == 127 || byte == 47 || byte == 92 || byte == 58) {
            return "invalid DLL name '${name}'"
        }
    }
    return ""
}

private func firstNonEmptyLine(primary: String, secondary: String): String {
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

func containsAsciiIgnoreCase(values: ArrayList<String>, candidate: String): Bool {
    for (value in values) {
        if (asciiEqualsIgnoreCaseForPe(value, candidate)) {
            return true
        }
    }
    return false
}

func asciiEqualsIgnoreCaseForPe(left: String, right: String): Bool {
    let leftBytes = left.toArray()
    let rightBytes = right.toArray()
    if (leftBytes.size != rightBytes.size) {
        return false
    }
    for (index in 0..leftBytes.size) {
        if (asciiLowerByteForPe(leftBytes[index]) != asciiLowerByteForPe(rightBytes[index])) {
            return false
        }
    }
    return true
}

private func startsWithAsciiIgnoreCase(value: String, prefix: String): Bool {
    let valueBytes = value.toArray()
    let prefixBytes = prefix.toArray()
    if (valueBytes.size < prefixBytes.size) {
        return false
    }
    for (index in 0..prefixBytes.size) {
        if (asciiLowerByteForPe(valueBytes[index]) != asciiLowerByteForPe(prefixBytes[index])) {
            return false
        }
    }
    return true
}

private func asciiLowerByteForPe(value: Byte): Byte {
    if (value >= 65 && value <= 90) {
        return value + 32
    }
    return value
}
