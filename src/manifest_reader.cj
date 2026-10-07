package cjdist

import std.collection.ArrayList
import std.fs.Path
import std.unicode.*

class ManifestLoadResult {
    let success: Bool
    let manifest: ?Manifest
    let error: String
    public init(manifest: Manifest) { success = true; this.manifest = Some(manifest); error = "" }
    public init(error: String) { success = false; manifest = None; this.error = error }
}

func parseManifest(source: String): ManifestLoadResult {
    let parsed = parseStrictJson(source)
    if (!parsed.success) { return ManifestLoadResult("Malformed manifest JSON: ${parsed.error}") }
    let root = match (parsed.value) { case Some(value) => value; case None => return ManifestLoadResult("Manifest JSON has no root value.") }
    let topError = requireObjectKeys(root, ["schemaVersion", "cjdistVersion", "application", "runtime", "toolchain", "verify", "directories", "files"], "manifest")
    if (!topError.isEmpty()) { return ManifestLoadResult(topError) }

    let schema = integerField(root, "schemaVersion", "manifest")
    if (!schema.success) { return ManifestLoadResult(schema.error) }
    if (schema.number != 1) { return ManifestLoadResult("Unsupported manifest schemaVersion: ${schema.number}") }
    let cjdistVersion = stringField(root, "cjdistVersion", "manifest")
    if (!cjdistVersion.success) { return ManifestLoadResult(cjdistVersion.error) }

    let application = objectField(root, "application", "manifest")
    if (!application.success) { return ManifestLoadResult(application.error) }
    let app = application.value
    let appKeys = requireObjectKeys(app, ["name", "entry"], "application")
    if (!appKeys.isEmpty()) { return ManifestLoadResult(appKeys) }
    let name = stringField(app, "name", "application")
    let entry = stringField(app, "entry", "application")
    if (!name.success) { return ManifestLoadResult(name.error) }
    if (!entry.success) { return ManifestLoadResult(entry.error) }

    let runtimeValue = objectField(root, "runtime", "manifest")
    if (!runtimeValue.success) { return ManifestLoadResult(runtimeValue.error) }
    let runtime = runtimeValue.value
    let runtimeKeys = requireObjectKeys(runtime, ["mode"], "runtime")
    if (!runtimeKeys.isEmpty()) { return ManifestLoadResult(runtimeKeys) }
    let mode = stringField(runtime, "mode", "runtime")
    if (!mode.success) { return ManifestLoadResult(mode.error) }

    let toolchainValue = objectField(root, "toolchain", "manifest")
    if (!toolchainValue.success) { return ManifestLoadResult(toolchainValue.error) }
    let toolchain = toolchainValue.value
    let toolchainKeys = requireObjectKeys(toolchain, ["cjcVersion", "cjpmVersion", "target"], "toolchain")
    if (!toolchainKeys.isEmpty()) { return ManifestLoadResult(toolchainKeys) }
    let cjcVersion = stringField(toolchain, "cjcVersion", "toolchain")
    let cjpmVersion = stringField(toolchain, "cjpmVersion", "toolchain")
    let target = stringField(toolchain, "target", "toolchain")
    if (!cjcVersion.success) { return ManifestLoadResult(cjcVersion.error) }
    if (!cjpmVersion.success) { return ManifestLoadResult(cjpmVersion.error) }
    if (!target.success) { return ManifestLoadResult(target.error) }

    let verifyValue = objectField(root, "verify", "manifest")
    if (!verifyValue.success) { return ManifestLoadResult(verifyValue.error) }
    let verifyObject = verifyValue.value
    let verifyKeys = requireObjectKeys(verifyObject, ["args", "expectedExitCode", "timeoutMs", "workingDirectory"], "verify")
    if (!verifyKeys.isEmpty()) { return ManifestLoadResult(verifyKeys) }
    let argsValue = arrayField(verifyObject, "args", "verify")
    let expected = integerField(verifyObject, "expectedExitCode", "verify")
    let timeout = integerField(verifyObject, "timeoutMs", "verify")
    let working = stringField(verifyObject, "workingDirectory", "verify")
    if (!argsValue.success) { return ManifestLoadResult(argsValue.error) }
    if (!expected.success) { return ManifestLoadResult(expected.error) }
    if (!timeout.success) { return ManifestLoadResult(timeout.error) }
    if (!working.success) { return ManifestLoadResult(working.error) }
    let args = ArrayList<String>()
    for (value in argsValue.value.elements) {
        if (value.kind != "string") { return ManifestLoadResult("verify.args must contain only strings.") }
        args.add(value.text)
    }

    let directoriesValue = arrayField(root, "directories", "manifest")
    if (!directoriesValue.success) { return ManifestLoadResult(directoriesValue.error) }
    let directories = ArrayList<String>()
    for (value in directoriesValue.value.elements) {
        if (value.kind != "string") { return ManifestLoadResult("manifest.directories must contain only strings.") }
        directories.add(value.text)
    }

    let filesValue = arrayField(root, "files", "manifest")
    if (!filesValue.success) { return ManifestLoadResult(filesValue.error) }
    let files = ArrayList<ManifestFile>()
    for (index in 0..filesValue.value.elements.size) {
        let value = filesValue.value.elements[index]
        let context = "files[${index}]"
        let keys = requireObjectKeys(value, ["path", "kind", "size", "sha256"], context)
        if (!keys.isEmpty()) { return ManifestLoadResult(keys) }
        let path = stringField(value, "path", context)
        let kind = stringField(value, "kind", context)
        let size = integerField(value, "size", context)
        let hash = stringField(value, "sha256", context)
        if (!path.success) { return ManifestLoadResult(path.error) }
        if (!kind.success) { return ManifestLoadResult(kind.error) }
        if (!size.success) { return ManifestLoadResult(size.error) }
        if (!hash.success) { return ManifestLoadResult(hash.error) }
        files.add(ManifestFile(path.text, kind.text, size.number, hash.text))
    }

    let manifest = Manifest(
        schema.number, cjdistVersion.text, name.text, entry.text, mode.text,
        cjcVersion.text, cjpmVersion.text, target.text,
        ManifestVerify(args.toArray(), expected.number, timeout.number, working.text),
        files.toArray(), directories.toArray()
    )
    let semanticError = validateManifestSemantics(manifest)
    if (!semanticError.isEmpty()) { return ManifestLoadResult(semanticError) }
    return ManifestLoadResult(manifest)
}

private class JsonFieldResult {
    let success: Bool; let value: JsonValue; let text: String; let number: Int64; let error: String
    public init(value: JsonValue) { success = true; this.value = value; text = value.text; number = value.number; error = "" }
    public init(error: String) { success = false; value = JsonValue("invalid", "", 0, [], []); text = ""; number = 0; this.error = error }
}

private func findField(object: JsonValue, name: String): ?JsonValue {
    for (member in object.members) { if (member.name == name) { return Some(member.value) } }
    return None
}
private func typedField(object: JsonValue, name: String, kind: String, context: String): JsonFieldResult {
    return match (findField(object, name)) {
        case Some(value) => if (value.kind == kind) { JsonFieldResult(value) } else { JsonFieldResult("${context}.${name} must be ${kind}.") }
        case None => JsonFieldResult("Missing required key ${context}.${name}.")
    }
}
private func stringField(object: JsonValue, name: String, context: String): JsonFieldResult { typedField(object, name, "string", context) }
private func integerField(object: JsonValue, name: String, context: String): JsonFieldResult { typedField(object, name, "integer", context) }
private func objectField(object: JsonValue, name: String, context: String): JsonFieldResult { typedField(object, name, "object", context) }
private func arrayField(object: JsonValue, name: String, context: String): JsonFieldResult { typedField(object, name, "array", context) }

private func requireObjectKeys(value: JsonValue, allowed: Array<String>, context: String): String {
    if (value.kind != "object") { return "${context} must be an object." }
    for (member in value.members) {
        var known = false
        for (name in allowed) { if (member.name == name) { known = true; break } }
        if (!known) { return "Unknown key ${context}.${member.name}." }
    }
    for (name in allowed) {
        if (findField(value, name).isNone()) { return "Missing required key ${context}.${name}." }
    }
    return ""
}

func validateManifestSemantics(manifest: Manifest): String {
    if (manifest.schemaVersion != 1) { return "Unsupported manifest schemaVersion: ${manifest.schemaVersion}" }
    if (manifest.cjdistVersion.trim().isEmpty()) { return "Manifest cjdistVersion must not be empty." }
    if (manifest.applicationName.trim().isEmpty()) { return "Manifest application.name must not be empty." }
    let entryError = validateDistributionPath(manifest.entry, "application.entry")
    if (!entryError.isEmpty()) { return entryError }
    if (manifest.runtimeMode != "dynamic" && manifest.runtimeMode != "static") {
        return "Manifest runtime.mode must be 'dynamic' or 'static'."
    }
    for ((label, value) in [("toolchain.cjcVersion", manifest.cjcVersion), ("toolchain.cjpmVersion", manifest.cjpmVersion), ("toolchain.target", manifest.target)]) {
        if (!isReasonableManifestText(value)) { return "Manifest ${label} is empty or contains control characters." }
    }
    if (manifest.verify.timeoutMs <= 0 || manifest.verify.timeoutMs > MAX_VERIFY_TIMEOUT_MS) {
        return "Manifest verify.timeoutMs must be between 1 and ${MAX_VERIFY_TIMEOUT_MS}."
    }
    if (manifest.verify.workingDirectory != "package-root") { return "Manifest verify.workingDirectory must be 'package-root'." }
    if (manifest.files.isEmpty()) { return "Manifest files must not be empty." }

    var entryCount: Int64 = 0
    var markerCount: Int64 = 0
    for (index in 0..manifest.files.size) {
        let file = manifest.files[index]
        let pathError = validateDistributionPath(file.path, "files[${index}].path")
        if (!pathError.isEmpty()) { return pathError }
        if (asciiEqualsIgnoreCaseForPe(file.path, MANIFEST_FILE_NAME)) { return "The manifest must not list itself in files." }
        if (!isKnownManifestKind(file.kind)) { return "Unknown manifest file kind '${file.kind}'." }
        if (file.size < 0) { return "Manifest file size must not be negative: ${file.path}" }
        if (!isSha256(file.sha256)) { return "Manifest SHA-256 must be exactly 64 hexadecimal characters: ${file.path}" }
        if (manifest.runtimeMode == "static" && file.kind == "runtime") {
            return "Static distributions must not contain SDK Runtime files: ${file.path}"
        }
        if (file.kind == "entry") {
            entryCount++
            if (file.path != manifest.entry) { return "The entry file path does not exactly match application.entry." }
        }
        if (asciiEqualsIgnoreCaseForPe(file.path, OUTPUT_MARKER_NAME)) {
            markerCount++
            if (file.kind != "metadata") { return "${OUTPUT_MARKER_NAME} must have kind 'metadata'." }
        }
        for (prior in 0..index) {
            let other = manifest.files[prior]
            if (asciiEqualsIgnoreCaseForPe(other.path, file.path)) { return "Duplicate manifest file path (ASCII case-insensitive): ${file.path}" }
            if (isPathAncestor(other.path, file.path) || isPathAncestor(file.path, other.path)) { return "Manifest file hierarchy conflict: ${file.path}" }
        }
    }
    if (entryCount != 1) { return "Manifest must contain exactly one file with kind 'entry'." }
    if (markerCount != 1) { return "Manifest must contain ${OUTPUT_MARKER_NAME} exactly once." }

    for (index in 0..manifest.directories.size) {
        let directory = manifest.directories[index]
        let pathError = validateDistributionPath(directory, "directories[${index}]")
        if (!pathError.isEmpty()) { return pathError }
        for (prior in 0..index) {
            if (asciiEqualsIgnoreCaseForPe(manifest.directories[prior], directory)) { return "Duplicate manifest directory (ASCII case-insensitive): ${directory}" }
        }
        for (file in manifest.files) {
            if (asciiEqualsIgnoreCaseForPe(file.path, directory) || isPathAncestor(file.path, directory)) { return "Manifest file/directory path conflict: ${directory}" }
        }
    }
    return ""
}

private func validateDistributionPath(value: String, label: String): String {
    if (value.isEmpty() || value.contains("\\") || value.contains(":")) { return "Manifest ${label} is not a safe distribution-relative path." }
    let path = Path(value)
    if (path.isAbsolute()) { return "Manifest ${label} must be relative." }
    let normalized = manifestStylePath(path.normalize())
    if (normalized == "." || normalized != value || normalized == ".." || normalized.startsWith("../")) {
        return "Manifest ${label} is not a normalized safe relative path."
    }
    return ""
}
private func manifestStylePath(path: Path): String {
    let bytes = path.toString().toArray()
    for (index in 0..bytes.size) { if (bytes[index] == 92) { bytes[index] = 47 } }
    return String.fromUtf8(bytes)
}
func isPathAncestor(parent: String, child: String): Bool {
    let prefix = if (parent.endsWith("/")) { parent } else { parent + "/" }
    let left = asciiLower(child); let right = asciiLower(prefix)
    return left.startsWith(right)
}
private func asciiLower(value: String): String {
    let bytes = value.toArray()
    for (index in 0..bytes.size) { if (bytes[index] >= 65 && bytes[index] <= 90) { bytes[index] += 32 } }
    return String.fromUtf8(bytes)
}
private func isKnownManifestKind(value: String): Bool {
    return value == "entry" || value == "runtime" || value == "dll" || value == "resource" || value == "license" || value == "metadata"
}
private func isSha256(value: String): Bool {
    let bytes = value.toArray(); if (bytes.size != 64) { return false }
    for (byte in bytes) { if (!((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102))) { return false } }
    return true
}
private func isReasonableManifestText(value: String): Bool {
    if (value.trim().isEmpty()) { return false }
    for (byte in value.toArray()) { if (byte < 32 || byte == 127) { return false } }
    return true
}
