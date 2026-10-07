package cjdist

import std.collection.ArrayList
import std.convert.*
import std.env.getWorkingDirectory
import std.fs.File
import std.fs.Path
import std.unicode.*

// CJDist intentionally accepts only the TOML subset needed by the schema below.
// Unsupported TOML syntax is rejected instead of being guessed or ignored.

let MAX_VERIFY_TIMEOUT_MS: Int64 = 300000

class RuntimeConfig {
    let mode: String
    let source: String

    public init(mode: String, source: String) {
        this.mode = mode
        this.source = source
    }
}

class FilesConfig {
    let include: Array<String>
    let dlls: Array<String>
    let licenses: Array<String>

    public init(include: Array<String>, dlls: Array<String>, licenses: Array<String>) {
        this.include = include
        this.dlls = dlls
        this.licenses = licenses
    }
}

class VerifyConfig {
    let args: Array<String>
    let expectedExitCode: Int64
    let timeoutMs: Int64
    let workingDirectory: String

    public init(
        args: Array<String>,
        expectedExitCode: Int64,
        timeoutMs: Int64,
        workingDirectory: String
    ) {
        this.args = args
        this.expectedExitCode = expectedExitCode
        this.timeoutMs = timeoutMs
        this.workingDirectory = workingDirectory
    }
}

class DistConfig {
    let name: String
    let entry: String
    let outputDir: String
    let runtime: RuntimeConfig
    let files: FilesConfig
    let verify: VerifyConfig

    public init(
        name: String,
        entry: String,
        outputDir: String,
        runtime: RuntimeConfig,
        files: FilesConfig,
        verify: VerifyConfig
    ) {
        this.name = name
        this.entry = entry
        this.outputDir = outputDir
        this.runtime = runtime
        this.files = files
        this.verify = verify
    }
}

class ConfigLoadResult {
    let success: Bool
    let config: ?DistConfig
    let error: String

    public init(config: DistConfig) {
        this.success = true
        this.config = Some(config)
        this.error = ""
    }

    public init(error: String) {
        this.success = false
        this.config = None
        this.error = error
    }
}

private class RawSection {
    let name: String
    let line: Int64

    public init(name: String, line: Int64) {
        this.name = name
        this.line = line
    }
}

private class RawEntry {
    let section: String
    let key: String
    let value: String
    let line: Int64

    public init(section: String, key: String, value: String, line: Int64) {
        this.section = section
        this.key = key
        this.value = value
        this.line = line
    }
}

private class RawDocument {
    let sections: ArrayList<RawSection>
    let entries: ArrayList<RawEntry>

    public init(sections: ArrayList<RawSection>, entries: ArrayList<RawEntry>) {
        this.sections = sections
        this.entries = entries
    }
}

private class RawParseResult {
    let document: ?RawDocument
    let error: String

    public init(document: RawDocument) {
        this.document = Some(document)
        this.error = ""
    }

    public init(error: String) {
        this.document = None
        this.error = error
    }
}

private class TextResult {
    let success: Bool
    let value: String
    let error: String

    public init(success: Bool, value: String, error: String) {
        this.success = success
        this.value = value
        this.error = error
    }
}

private class StringAtResult {
    let success: Bool
    let value: String
    let nextIndex: Int64
    let error: String

    public init(success: Bool, value: String, nextIndex: Int64, error: String) {
        this.success = success
        this.value = value
        this.nextIndex = nextIndex
        this.error = error
    }
}

private class IntegerResult {
    let success: Bool
    let value: Int64
    let error: String

    public init(success: Bool, value: Int64, error: String) {
        this.success = success
        this.value = value
        this.error = error
    }
}

private class StringArrayResult {
    let success: Bool
    let value: Array<String>
    let error: String

    public init(success: Bool, value: Array<String>, error: String) {
        this.success = success
        this.value = value
        this.error = error
    }
}

func loadDistConfig(fileName: String): ConfigLoadResult {
    let source: String
    try {
        let configPath = getWorkingDirectory().join(fileName)
        source = String.fromUtf8(File.readFrom(configPath))
    } catch (e: Exception) {
        return ConfigLoadResult("${fileName}: unable to read required configuration: ${e.message}")
    }

    let parsed = parseRestrictedToml(source, fileName)
    match (parsed.document) {
        case Some(document) => return validateDocument(document, fileName)
        case None => return ConfigLoadResult(parsed.error)
    }
}

private func parseRestrictedToml(source: String, fileName: String): RawParseResult {
    let sections = ArrayList<RawSection>()
    let entries = ArrayList<RawEntry>()
    var currentSection = ""
    var lineNumber: Int64 = 0
    var collectingArray = false
    var pendingSection = ""
    var pendingKey = ""
    var pendingValue = ""
    var pendingLine: Int64 = 0

    for (sourceLine in source.lines()) {
        lineNumber++
        let commentResult = stripComment(sourceLine)
        if (!commentResult.success) {
            return parseError(fileName, lineNumber, commentResult.error)
        }
        let line = commentResult.value.trim()

        if (collectingArray) {
            pendingValue = pendingValue + "\n" + line
            if (isArrayClosed(pendingValue)) {
                entries.add(RawEntry(pendingSection, pendingKey, pendingValue.trim(), pendingLine))
                collectingArray = false
                pendingSection = ""
                pendingKey = ""
                pendingValue = ""
                pendingLine = 0
            }
            continue
        }

        if (line.isEmpty()) {
            continue
        }

        if (line.startsWith("[")) {
            if (!line.endsWith("]") || line.size < 3) {
                return parseError(fileName, lineNumber, "malformed table header")
            }
            let sectionName = line[1..(line.size - 1)].trim()
            if (!isBareSectionName(sectionName)) {
                return parseError(fileName, lineNumber, "unsupported or malformed table name '${sectionName}'")
            }
            for (section in sections) {
                if (section.name == sectionName) {
                    return parseError(fileName, lineNumber, "duplicate table '[${sectionName}]'")
                }
            }
            sections.add(RawSection(sectionName, lineNumber))
            currentSection = sectionName
            continue
        }

        if (currentSection.isEmpty()) {
            return parseError(fileName, lineNumber, "keys must appear inside a supported table")
        }

        let equalsIndex = findAssignment(line)
        if (equalsIndex < 0) {
            return parseError(fileName, lineNumber, "expected 'key = value'")
        }
        let key = line[0..equalsIndex].trim()
        let value = line[(equalsIndex + 1)..].trim()
        if (!isBareKey(key)) {
            return parseError(fileName, lineNumber, "unsupported or malformed key '${key}'")
        }
        if (value.isEmpty()) {
            return parseError(fileName, lineNumber, "missing value for '${currentSection}.${key}'")
        }

        if (value.startsWith("[") && !isArrayClosed(value)) {
            collectingArray = true
            pendingSection = currentSection
            pendingKey = key
            pendingValue = value
            pendingLine = lineNumber
        } else {
            entries.add(RawEntry(currentSection, key, value, lineNumber))
        }
    }

    if (collectingArray) {
        return parseError(fileName, pendingLine, "unterminated array for '${pendingSection}.${pendingKey}'")
    }

    return RawParseResult(RawDocument(sections, entries))
}

private func validateDocument(document: RawDocument, fileName: String): ConfigLoadResult {
    for (section in document.sections) {
        if (
            section.name != "dist" &&
            section.name != "dist.runtime" &&
            section.name != "dist.files" &&
            section.name != "dist.verify"
        ) {
            return validationError(fileName, section.line, "unknown table '[${section.name}]'")
        }
    }

    var name = ""
    var entryPath = ""
    var outputDir = ""
    var runtimeMode = "dynamic"
    var runtimeSource = "build-sdk"
    var include: Array<String> = []
    var dlls: Array<String> = []
    var licenses: Array<String> = []
    var verifyArgs: Array<String> = []
    var expectedExitCode: Int64 = 0
    var timeoutMs: Int64 = 5000
    var workingDirectory = "package-root"

    var hasName = false
    var hasEntry = false
    var hasOutputDir = false
    var hasRuntimeMode = false
    var hasRuntimeSource = false
    var hasInclude = false
    var hasDlls = false
    var hasLicenses = false
    var hasVerifyArgs = false
    var hasExpectedExitCode = false
    var hasTimeoutMs = false
    var hasWorkingDirectory = false

    for (raw in document.entries) {
        let field = "${raw.section}.${raw.key}"

        if (field == "dist.name") {
            if (hasName) { return duplicateField(fileName, raw) }
            let parsed = parseStringValue(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            name = parsed.value
            hasName = true
        } else if (field == "dist.entry") {
            if (hasEntry) { return duplicateField(fileName, raw) }
            let parsed = parseStringValue(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            entryPath = parsed.value
            hasEntry = true
        } else if (field == "dist.output-dir") {
            if (hasOutputDir) { return duplicateField(fileName, raw) }
            let parsed = parseStringValue(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            outputDir = parsed.value
            hasOutputDir = true
        } else if (field == "dist.runtime.mode") {
            if (hasRuntimeMode) { return duplicateField(fileName, raw) }
            let parsed = parseStringValue(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            runtimeMode = parsed.value
            hasRuntimeMode = true
        } else if (field == "dist.runtime.source") {
            if (hasRuntimeSource) { return duplicateField(fileName, raw) }
            let parsed = parseStringValue(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            runtimeSource = parsed.value
            hasRuntimeSource = true
        } else if (field == "dist.files.include") {
            if (hasInclude) { return duplicateField(fileName, raw) }
            let parsed = parseStringArray(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            include = parsed.value
            hasInclude = true
        } else if (field == "dist.files.dlls") {
            if (hasDlls) { return duplicateField(fileName, raw) }
            let parsed = parseStringArray(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            dlls = parsed.value
            hasDlls = true
        } else if (field == "dist.files.licenses") {
            if (hasLicenses) { return duplicateField(fileName, raw) }
            let parsed = parseStringArray(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            licenses = parsed.value
            hasLicenses = true
        } else if (field == "dist.verify.args") {
            if (hasVerifyArgs) { return duplicateField(fileName, raw) }
            let parsed = parseStringArray(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            verifyArgs = parsed.value
            hasVerifyArgs = true
        } else if (field == "dist.verify.expected-exit-code") {
            if (hasExpectedExitCode) { return duplicateField(fileName, raw) }
            let parsed = parseDecimalInteger(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            expectedExitCode = parsed.value
            hasExpectedExitCode = true
        } else if (field == "dist.verify.timeout-ms") {
            if (hasTimeoutMs) { return duplicateField(fileName, raw) }
            let parsed = parseDecimalInteger(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            timeoutMs = parsed.value
            hasTimeoutMs = true
        } else if (field == "dist.verify.working-directory") {
            if (hasWorkingDirectory) { return duplicateField(fileName, raw) }
            let parsed = parseStringValue(raw.value)
            if (!parsed.success) { return invalidField(fileName, raw, parsed.error) }
            workingDirectory = parsed.value
            hasWorkingDirectory = true
        } else {
            return validationError(fileName, raw.line, "unknown field '${field}'")
        }
    }

    if (!hasName) { return ConfigLoadResult("${fileName}: missing required field 'dist.name'") }
    if (!hasEntry) { return ConfigLoadResult("${fileName}: missing required field 'dist.entry'") }
    if (!hasOutputDir) { return ConfigLoadResult("${fileName}: missing required field 'dist.output-dir'") }

    if (name.trim().isEmpty()) {
        return ConfigLoadResult("${fileName}: field 'dist.name' must not be empty")
    }

    let entryError = validateProjectRelativePath(entryPath, "dist.entry")
    if (!entryError.isEmpty()) { return ConfigLoadResult("${fileName}: ${entryError}") }
    let outputError = validateProjectRelativePath(outputDir, "dist.output-dir")
    if (!outputError.isEmpty()) { return ConfigLoadResult("${fileName}: ${outputError}") }

    if (runtimeMode != "dynamic" && runtimeMode != "static") {
        return ConfigLoadResult("${fileName}: field 'dist.runtime.mode' must be 'dynamic' or 'static'")
    }
    if (runtimeSource != "build-sdk") {
        return ConfigLoadResult("${fileName}: field 'dist.runtime.source' must be 'build-sdk'")
    }
    if (timeoutMs <= 0) {
        return ConfigLoadResult("${fileName}: field 'dist.verify.timeout-ms' must be greater than 0")
    }
    if (timeoutMs > MAX_VERIFY_TIMEOUT_MS) {
        return ConfigLoadResult(
            "${fileName}: field 'dist.verify.timeout-ms' must not exceed ${MAX_VERIFY_TIMEOUT_MS}"
        )
    }
    if (workingDirectory != "package-root") {
        return ConfigLoadResult(
            "${fileName}: field 'dist.verify.working-directory' must be 'package-root' in v0.1"
        )
    }

    let includeError = validatePathArray(include, "dist.files.include")
    if (!includeError.isEmpty()) { return ConfigLoadResult("${fileName}: ${includeError}") }
    let dllError = validatePathArray(dlls, "dist.files.dlls")
    if (!dllError.isEmpty()) { return ConfigLoadResult("${fileName}: ${dllError}") }
    let licenseError = validatePathArray(licenses, "dist.files.licenses")
    if (!licenseError.isEmpty()) { return ConfigLoadResult("${fileName}: ${licenseError}") }

    return ConfigLoadResult(
        DistConfig(
            name,
            entryPath,
            outputDir,
            RuntimeConfig(runtimeMode, runtimeSource),
            FilesConfig(include, dlls, licenses),
            VerifyConfig(verifyArgs, expectedExitCode, timeoutMs, workingDirectory)
        )
    )
}

private func stripComment(line: String): TextResult {
    let bytes = line.toArray()
    var inString = false
    var escaped = false
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (inString) {
            if (escaped) {
                escaped = false
            } else if (byte == 92) {
                escaped = true
            } else if (byte == 34) {
                inString = false
            }
        } else if (byte == 34) {
            inString = true
        } else if (byte == 35) {
            return TextResult(true, line[0..index], "")
        }
    }
    if (inString) {
        return TextResult(false, "", "unterminated basic string; multiline strings are not supported")
    }
    return TextResult(true, line, "")
}

private func isArrayClosed(value: String): Bool {
    let bytes = value.toArray()
    var depth: Int64 = 0
    var inString = false
    var escaped = false
    for (byte in bytes) {
        if (inString) {
            if (escaped) {
                escaped = false
            } else if (byte == 92) {
                escaped = true
            } else if (byte == 34) {
                inString = false
            }
        } else if (byte == 34) {
            inString = true
        } else if (byte == 91) {
            depth++
        } else if (byte == 93) {
            depth--
            if (depth <= 0) { return true }
        }
    }
    return false
}

private func findAssignment(line: String): Int64 {
    let bytes = line.toArray()
    for (index in 0..bytes.size) {
        if (bytes[index] == 61) { return index }
    }
    return -1
}

private func isBareKey(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (byte in value.toArray()) {
        if (!isAlphaNumeric(byte) && byte != 95 && byte != 45) { return false }
    }
    return true
}

private func isBareSectionName(value: String): Bool {
    if (value.isEmpty() || value.startsWith(".") || value.endsWith(".")) { return false }
    var lastWasDot = false
    for (byte in value.toArray()) {
        if (byte == 46) {
            if (lastWasDot) { return false }
            lastWasDot = true
        } else {
            if (!isAlphaNumeric(byte) && byte != 95 && byte != 45) { return false }
            lastWasDot = false
        }
    }
    return true
}

private func isAlphaNumeric(byte: Byte): Bool {
    return (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
}

private func isSupportedWhitespace(byte: Byte): Bool {
    return byte == 32 || byte == 9 || byte == 10 || byte == 13
}

private func skipWhitespace(bytes: Array<Byte>, start: Int64): Int64 {
    var index = start
    while (index < bytes.size && isSupportedWhitespace(bytes[index])) {
        index++
    }
    return index
}

private func parseStringValue(raw: String): StringAtResult {
    let parsed = parseBasicStringAt(raw, 0)
    if (!parsed.success) { return parsed }
    let bytes = raw.toArray()
    let tail = skipWhitespace(bytes, parsed.nextIndex)
    if (tail != bytes.size) {
        return StringAtResult(false, "", 0, "expected exactly one basic quoted string")
    }
    return parsed
}

private func parseBasicStringAt(raw: String, start: Int64): StringAtResult {
    let bytes = raw.toArray()
    if (start >= bytes.size || bytes[start] != 34) {
        return StringAtResult(false, "", 0, "expected a basic quoted string")
    }

    let builder = StringBuilder()
    var index = start + 1
    var chunkStart = index
    while (index < bytes.size) {
        let byte = bytes[index]
        if (byte == 34) {
            if (index > chunkStart) { builder.append(raw[chunkStart..index]) }
            return StringAtResult(true, builder.toString(), index + 1, "")
        }
        if (byte == 92) {
            if (index > chunkStart) { builder.append(raw[chunkStart..index]) }
            if (index + 1 >= bytes.size) {
                return StringAtResult(false, "", 0, "unterminated escape sequence")
            }
            let escaped = bytes[index + 1]
            if (escaped == 34) {
                builder.append("\"")
            } else if (escaped == 92) {
                builder.append("\\")
            } else if (escaped == 110) {
                builder.append("\n")
            } else if (escaped == 114) {
                builder.append("\r")
            } else if (escaped == 116) {
                builder.append("\t")
            } else {
                return StringAtResult(false, "", 0, "unsupported escape sequence in basic string")
            }
            index += 2
            chunkStart = index
            continue
        }
        if (byte < 32 && byte != 9) {
            return StringAtResult(false, "", 0, "control character is not allowed in a basic string")
        }
        index++
    }
    return StringAtResult(false, "", 0, "unterminated basic string")
}

private func parseDecimalInteger(raw: String): IntegerResult {
    let value = raw.trim()
    let bytes = value.toArray()
    if (bytes.size == 0) {
        return IntegerResult(false, 0, "expected a decimal integer")
    }
    var start: Int64 = 0
    if (bytes[0] == 45) {
        start = 1
        if (bytes.size == 1) { return IntegerResult(false, 0, "expected a decimal integer") }
    }
    for (index in start..bytes.size) {
        if (bytes[index] < 48 || bytes[index] > 57) {
            return IntegerResult(false, 0, "expected a decimal integer")
        }
    }
    match (Int64.tryParse(value)) {
        case Some(number) => return IntegerResult(true, number, "")
        case None => return IntegerResult(false, 0, "decimal integer is outside the Int64 range")
    }
}

private func parseStringArray(raw: String): StringArrayResult {
    let bytes = raw.toArray()
    if (bytes.size < 2 || bytes[0] != 91) {
        return StringArrayResult(false, [], "expected an array of basic quoted strings")
    }

    let values = ArrayList<String>()
    var index: Int64 = 1
    while (true) {
        index = skipWhitespace(bytes, index)
        if (index >= bytes.size) {
            return StringArrayResult(false, [], "unterminated string array")
        }
        if (bytes[index] == 93) {
            index++
            index = skipWhitespace(bytes, index)
            if (index != bytes.size) {
                return StringArrayResult(false, [], "unexpected content after string array")
            }
            return StringArrayResult(true, values.toArray(), "")
        }
        if (bytes[index] != 34) {
            return StringArrayResult(false, [], "array elements must be basic quoted strings")
        }

        let parsed = parseBasicStringAt(raw, index)
        if (!parsed.success) {
            return StringArrayResult(false, [], parsed.error)
        }
        values.add(parsed.value)
        index = skipWhitespace(bytes, parsed.nextIndex)
        if (index >= bytes.size) {
            return StringArrayResult(false, [], "unterminated string array")
        }
        if (bytes[index] == 44) {
            index++
            continue
        }
        if (bytes[index] != 93) {
            return StringArrayResult(false, [], "expected ',' or ']' in string array")
        }
    }
    return StringArrayResult(false, [], "unreachable string array parser state")
}

private func validatePathArray(values: Array<String>, field: String): String {
    for (index in 0..values.size) {
        let error = validateProjectRelativePath(values[index], "${field}[${index}]")
        if (!error.isEmpty()) { return error }
    }
    return ""
}

private func validateProjectRelativePath(value: String, field: String): String {
    if (value.trim().isEmpty()) {
        return "field '${field}' must be a non-empty project-relative path"
    }
    for (byte in value.toArray()) {
        // A colon permits drive-relative paths (C:foo) or NTFS alternate data streams.
        if (byte == 58) {
            return "field '${field}' must not contain a Windows drive or stream prefix"
        }
    }

    try {
        let relative = Path(value)
        if (relative.isAbsolute()) {
            return "field '${field}' must be project-relative, not absolute"
        }

        let root = Path("C:\\CJDistProjectRoot").normalize()
        let candidate = root.join(relative).normalize()
        let rootText = root.toString()
        let candidateText = candidate.toString()
        if (candidateText == rootText) {
            return "field '${field}' must identify a path below the project root, not '.'"
        }
        if (!candidateText.startsWith(rootText + "\\")) {
            return "field '${field}' escapes the project root after normalization"
        }
    } catch (e: Exception) {
        return "field '${field}' is not a valid Windows path: ${e.message}"
    }
    return ""
}

private func parseError(fileName: String, line: Int64, message: String): RawParseResult {
    return RawParseResult("${fileName}:${line}: ${message}")
}

private func validationError(fileName: String, line: Int64, message: String): ConfigLoadResult {
    return ConfigLoadResult("${fileName}:${line}: ${message}")
}

private func invalidField(fileName: String, raw: RawEntry, message: String): ConfigLoadResult {
    return validationError(fileName, raw.line, "invalid field '${raw.section}.${raw.key}': ${message}")
}

private func duplicateField(fileName: String, raw: RawEntry): ConfigLoadResult {
    return validationError(fileName, raw.line, "duplicate field '${raw.section}.${raw.key}'")
}
