package cjdist

import std.env.getWorkingDirectory
import std.env.getTempDirectory
import std.fs.*

class VerificationResult {
    let success: Bool
    let manifest: ?Manifest
    let fileCount: Int64
    let startup: ?StartupResult
    let error: String
    public init(manifest: Manifest, fileCount: Int64, startup: StartupResult) {
        success = true; this.manifest = Some(manifest); this.fileCount = fileCount
        this.startup = Some(startup); error = ""
    }
    public init(error: String, startup!: ?StartupResult = None) {
        success = false; manifest = None; fileCount = 0; this.startup = startup; this.error = error
    }
}

func verifyDistribution(input: String): VerificationResult {
    let requested = Path(input)
    let absolute = if (requested.isAbsolute()) { requested.normalize() } else { getWorkingDirectory().join(requested).normalize() }
    return verifyDistribution(absolute)
}

func verifyDistribution(root: Path): VerificationResult {
    let rootResult = validateDistributionRoot(root)
    if (!rootResult.isEmpty()) { return VerificationResult(rootResult) }
    let canonicalRoot: Path
    try { canonicalRoot = canonicalize(root) }
    catch (e: Exception) { return VerificationResult("Unable to canonicalize distribution root: ${e.message}") }

    let manifestPath = canonicalRoot.join(MANIFEST_FILE_NAME)
    try {
        let info = FileInfo(manifestPath)
        if (info.isSymbolicLink() || !info.isRegular()) { return VerificationResult("${MANIFEST_FILE_NAME} is not a normal file.") }
        if (info.size > 16 * 1024 * 1024) { return VerificationResult("Manifest exceeds the 16 MiB safety limit.") }
    } catch (e: Exception) { return VerificationResult("Unable to read ${MANIFEST_FILE_NAME}: ${e.message}") }
    let source: String
    try { source = String.fromUtf8(File.readFrom(manifestPath)) }
    catch (e: Exception) { return VerificationResult("Unable to decode ${MANIFEST_FILE_NAME} as UTF-8: ${e.message}") }
    let loaded = parseManifest(source)
    if (!loaded.success) { return VerificationResult(loaded.error) }
    let manifest = match (loaded.manifest) { case Some(value) => value; case None => return VerificationResult("Manifest parser returned no typed manifest.") }

    let treeError = verifyExactTree(canonicalRoot, manifest)
    if (!treeError.isEmpty()) { return VerificationResult(treeError) }
    let integrityError = verifyPayloadIntegrity(canonicalRoot, manifest)
    if (!integrityError.isEmpty()) { return VerificationResult(integrityError) }
    let startup = runStartupProbe(canonicalRoot, manifest)
    if (!startup.success) { return VerificationResult(startup.error, startup: Some(startup)) }
    if (startup.exitCode != manifest.verify.expectedExitCode) {
        return VerificationResult(
            "startup probe exited with code ${startup.exitCode}; expected ${manifest.verify.expectedExitCode}.",
            startup: Some(startup)
        )
    }
    return VerificationResult(manifest, manifest.files.size, startup)
}

private func validateDistributionRoot(root: Path): String {
    try {
        let info = FileInfo(root)
        if (info.isSymbolicLink()) { return "Distribution root must not be a symlink, junction, or reparse point: ${root}" }
        if (!info.isDirectory()) { return "Distribution root is not a directory: ${root}" }
        return ""
    } catch (e: Exception) { return "Distribution root does not exist or is inaccessible: ${root}" }
}

private func verifyExactTree(root: Path, manifest: Manifest): String {
    for (file in manifest.files) {
        let path = root.join(Path(file.path)).normalize()
        if (!isPathInsideForFiles(path, root, false)) { return "Manifest file escapes distribution root: ${file.path}" }
        try {
            let info = FileInfo(path)
            if (info.isSymbolicLink()) { return "Distribution contains a symlink, junction, or reparse point: ${file.path}" }
            if (!info.isRegular()) { return "Manifest payload is not a normal file: ${file.path}" }
        } catch (e: Exception) { return "Missing manifest file: ${file.path}" }
    }
    for (directory in manifest.directories) {
        let path = root.join(Path(directory)).normalize()
        try {
            let info = FileInfo(path)
            if (info.isSymbolicLink()) { return "Distribution contains a symlink, junction, or reparse point: ${directory}" }
            if (!info.isDirectory()) { return "Manifest directory is not a normal directory: ${directory}" }
        } catch (e: Exception) { return "Missing manifest directory: ${directory}" }
    }
    return enumerateTree(root, root, manifest)
}

private func enumerateTree(root: Path, current: Path, manifest: Manifest): String {
    try {
        for (child in Directory.readFrom(current)) {
            let info = FileInfo(child.path)
            let relative = relativeManifestPath(root, child.path)
            if (info.isSymbolicLink()) { return "Distribution contains a symlink, junction, or reparse point: ${relative}" }
            if (info.isRegular()) {
                if (asciiEqualsIgnoreCaseForPe(relative, MANIFEST_FILE_NAME)) { continue }
                var expected = false
                for (file in manifest.files) { if (asciiEqualsIgnoreCaseForPe(file.path, relative)) { expected = true; break } }
                if (!expected) { return "Unexpected file in distribution: ${relative}" }
            } else if (info.isDirectory()) {
                if (!isExpectedDirectory(relative, manifest)) { return "Unexpected directory in distribution: ${relative}" }
                let nested = enumerateTree(root, child.path, manifest)
                if (!nested.isEmpty()) { return nested }
            } else { return "Unsupported filesystem object in distribution: ${relative}" }
        }
    } catch (e: Exception) { return "Unable to enumerate distribution tree: ${e.message}" }
    return ""
}

private func isExpectedDirectory(relative: String, manifest: Manifest): Bool {
    for (directory in manifest.directories) {
        if (asciiEqualsIgnoreCaseForPe(directory, relative) || isPathAncestor(relative, directory)) { return true }
    }
    for (file in manifest.files) { if (isPathAncestor(relative, file.path)) { return true } }
    return false
}

private func relativeManifestPath(root: Path, path: Path): String {
    let rootText = root.toString()
    var text = path.toString()[rootText.size..path.toString().size]
    while (text.startsWith("\\") || text.startsWith("/")) { text = text[1..text.size] }
    let bytes = text.toArray(); for (index in 0..bytes.size) { if (bytes[index] == 92) { bytes[index] = 47 } }
    return String.fromUtf8(bytes)
}

private func verifyPayloadIntegrity(root: Path, manifest: Manifest): String {
    let powershell = resolveSystemPowerShell()
    if (!powershell.success) { return powershell.error }
    let scriptPath: Path
    try {
        let placeholder = File.createTemp(getTempDirectory()); let original = placeholder.info.path; placeholder.close()
        scriptPath = Path(original.toString() + ".ps1")
        rename(original, to: scriptPath, overwrite: false)
        File.writeTo(scriptPath, SHA256_SCRIPT_CONTENT.toArray())
    } catch (e: Exception) { return "Unable to create SHA-256 helper: ${e.message}" }
    var error = ""
    for (file in manifest.files) {
        let path = root.join(Path(file.path)).normalize()
        try {
            let info = FileInfo(path)
            if (info.size != file.size) { error = "Size mismatch: ${file.path}"; break }
        } catch (e: Exception) { error = "Unable to inspect payload: ${file.path}"; break }
        let hash = calculateFileSha256(powershell.hash, scriptPath, path)
        if (!hash.success) { error = "Unable to hash '${file.path}': ${hash.error}"; break }
        if (!asciiEqualsIgnoreCaseForPe(hash.hash, file.sha256)) { error = "SHA-256 mismatch: ${file.path}"; break }
    }
    try { removeIfExists(scriptPath) } catch (ignored: Exception) {}
    return error
}
