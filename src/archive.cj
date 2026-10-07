package cjdist

import std.env.getTempDirectory
import std.env.getWorkingDirectory
import std.fs.*
import std.unicode.*

let ARCHIVE_TEMP_MARKER = ".cjdist-archive-temp"
let ARCHIVE_TEMP_MARKER_CONTENT = "CJDist owned archive temporary directory\n"
let ARCHIVE_COMPRESS_SCRIPT =
    "param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination)\n" +
    "$ErrorActionPreference = 'Stop'\n" +
    "Import-Module Microsoft.PowerShell.Archive -ErrorAction Stop\n" +
    "if (Test-Path -LiteralPath $Destination) { throw 'Archive destination already exists.' }\n" +
    "Compress-Archive -LiteralPath $Source -DestinationPath $Destination -CompressionLevel Optimal\n"
let ARCHIVE_EXPAND_SCRIPT =
    "param([Parameter(Mandatory=$true)][string]$Archive,[Parameter(Mandatory=$true)][string]$Destination)\n" +
    "$ErrorActionPreference = 'Stop'\n" +
    "Import-Module Microsoft.PowerShell.Archive -ErrorAction Stop\n" +
    "if (Test-Path -LiteralPath $Destination) { throw 'Extraction destination already exists.' }\n" +
    "Expand-Archive -LiteralPath $Archive -DestinationPath $Destination\n"

class ArchiveResult {
    let success: Bool
    let archivePath: String
    let rootName: String
    let sha256: String
    let fileCount: Int64
    let error: String
    public init(archivePath: String, rootName: String, sha256: String, fileCount: Int64) {
        success = true; this.archivePath = archivePath; this.rootName = rootName
        this.sha256 = sha256; this.fileCount = fileCount; error = ""
    }
    public init(error: String) {
        success = false; archivePath = ""; rootName = ""; sha256 = ""; fileCount = 0; this.error = error
    }
}

// Archive is intentionally a consumer of a complete distribution. Both the
// source tree and the freshly extracted ZIP are verified by the shared core.
func archiveDistribution(input: String): ArchiveResult {
    let sourceVerification = verifyDistribution(input)
    if (!sourceVerification.success) {
        match (sourceVerification.startup) { case Some(value) => reportStartupDiagnostics(value); case None => () }
        return ArchiveResult("Source distribution verification failed: ${sourceVerification.error}")
    }
    let manifest = match (sourceVerification.manifest) {
        case Some(value) => value
        case None => return ArchiveResult("Source verification returned no typed manifest.")
    }
    let requested = Path(input)
    let absolute = if (requested.isAbsolute()) { requested.normalize() } else { getWorkingDirectory().join(requested).normalize() }
    let sourceRoot: Path
    try { sourceRoot = canonicalize(absolute) }
    catch (e: Exception) { return ArchiveResult("Unable to canonicalize verified distribution: ${e.message}") }

    let rootName = deriveArchiveRootName(manifest.applicationName)
    let archiveName = rootName + ".zip"
    let output = sourceRoot.parent.join(archiveName).normalize()
    if (isPathInsideForFiles(output, sourceRoot, true)) { return ArchiveResult("Archive destination must be outside the distribution directory.") }
    try {
        if (exists(output)) { return ArchiveResult("Archive destination already exists; refusing to overwrite: ${output}") }
    } catch (e: Exception) { return ArchiveResult("Unable to inspect archive destination: ${e.message}") }

    let temp: Path
    try {
        temp = Directory.createTemp(getTempDirectory())
        File.writeTo(temp.join(ARCHIVE_TEMP_MARKER), ARCHIVE_TEMP_MARKER_CONTENT.toArray())
    } catch (e: Exception) { return ArchiveResult("Unable to create owned archive workspace: ${e.message}") }

    let stagedRoot = temp.join(rootName).normalize()
    let tempArchive = temp.join(archiveName).normalize()
    let extracted = temp.join("extracted").normalize()
    let compressScript = temp.join("compress.ps1").normalize()
    let expandScript = temp.join("expand.ps1").normalize()
    let hashScript = temp.join("sha256.ps1").normalize()

    let copyError = copyArchiveTree(sourceRoot, stagedRoot)
    if (!copyError.isEmpty()) { return failArchive(temp, "Unable to stage archive input: ${copyError}") }
    try {
        File.writeTo(compressScript, ARCHIVE_COMPRESS_SCRIPT.toArray())
        File.writeTo(expandScript, ARCHIVE_EXPAND_SCRIPT.toArray())
        File.writeTo(hashScript, SHA256_SCRIPT_CONTENT.toArray())
    } catch (e: Exception) { return failArchive(temp, "Unable to create fixed archive helper scripts: ${e.message}") }

    let powershell = resolveSystemPowerShell()
    if (!powershell.success) { return failArchive(temp, powershell.error) }
    let compressed = runCaptured(
        powershell.hash,
        ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", compressScript.toString(), "-Source", stagedRoot.toString(), "-Destination", tempArchive.toString()],
        temp
    )
    let compressError = strictArchiveCommandError("Compress-Archive", compressed)
    if (!compressError.isEmpty()) { return failArchive(temp, compressError) }
    let expanded = runCaptured(
        powershell.hash,
        ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", expandScript.toString(), "-Archive", tempArchive.toString(), "-Destination", extracted.toString()],
        temp
    )
    let expandError = strictArchiveCommandError("Expand-Archive", expanded)
    if (!expandError.isEmpty()) { return failArchive(temp, expandError) }

    let layoutError = validateExtractedArchiveLayout(extracted, rootName)
    if (!layoutError.isEmpty()) { return failArchive(temp, layoutError) }
    let extractedRoot = extracted.join(rootName).normalize()
    if (!filesHaveSameBytes(sourceRoot.join(MANIFEST_FILE_NAME), extractedRoot.join(MANIFEST_FILE_NAME))) {
        return failArchive(temp, "Extracted archive manifest is not byte-for-byte identical to the verified source manifest.")
    }
    let extractedVerification = verifyDistribution(extractedRoot)
    if (!extractedVerification.success) {
        match (extractedVerification.startup) { case Some(value) => reportStartupDiagnostics(value); case None => () }
        return failArchive(temp, "Extracted archive verification failed: ${extractedVerification.error}")
    }

    let hash = calculateFileSha256(powershell.hash, hashScript, tempArchive)
    if (!hash.success) { return failArchive(temp, "Unable to hash completed archive: ${hash.error}") }

    // Remove all expanded/staged data and helper scripts before publication so
    // no helper, log, or extraction artifact can leak into the deliverable.
    let pruneError = pruneArchiveWorkspace(temp, stagedRoot, extracted, [compressScript, expandScript, hashScript])
    if (!pruneError.isEmpty()) { return failArchive(temp, pruneError) }
    try {
        if (exists(output)) { return failArchive(temp, "Archive destination appeared during creation; refusing to overwrite: ${output}") }
        rename(tempArchive, to: output, overwrite: false)
    } catch (e: Exception) {
        return failArchive(temp, "Unable to publish archive without overwrite: ${e.message}")
    }
    // Publication is the success boundary: every verification and the archive
    // hash completed before the no-overwrite rename. Empty-workspace cleanup is
    // best effort and must not turn a valid published artifact into a reported
    // failure while leaving that artifact in place.
    try {
        removeIfExists(temp.join(ARCHIVE_TEMP_MARKER))
        remove(temp)
    } catch (ignored: Exception) {}
    return ArchiveResult(output.toString(), rootName, hash.hash, sourceVerification.fileCount)
}

func deriveArchiveRootName(applicationName: String): String {
    let builder = StringBuilder()
    var lastSeparator = false
    for (byte in applicationName.trim().toArray()) {
        let safe = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) || byte == 45 || byte == 46 || byte == 95
        if (safe) {
            let one: Array<Byte> = [byte]
            builder.append(String.fromUtf8(one)); lastSeparator = false
        } else if (!lastSeparator) {
            builder.append("-"); lastSeparator = true
        }
    }
    var value = builder.toString()
    while (!value.isEmpty() && (value.startsWith("-") || value.startsWith("."))) { value = value[1..value.size] }
    while (!value.isEmpty() && (value.endsWith("-") || value.endsWith("."))) { value = value[0..(value.size - 1)] }
    if (value.isEmpty()) { value = "application" }
    if (value.size > 64) { value = value[0..64] }
    while (!value.isEmpty() && (value.endsWith("-") || value.endsWith("."))) { value = value[0..(value.size - 1)] }
    if (value.isEmpty()) { value = "application" }
    return value + "-windows-x64"
}

private func copyArchiveTree(source: Path, destination: Path): String {
    try {
        let sourceInfo = FileInfo(source)
        if (sourceInfo.isSymbolicLink() || !sourceInfo.isDirectory()) { return "source is not a normal directory: ${source}" }
        Directory.create(destination, recursive: true)
        for (child in Directory.readFrom(source)) {
            if (child.isSymbolicLink()) { return "source contains a reparse point: ${child.path}" }
            let target = destination.join(child.name).normalize()
            if (child.isDirectory()) {
                let error = copyArchiveTree(child.path.normalize(), target)
                if (!error.isEmpty()) { return error }
            } else if (child.isRegular()) {
                copy(child.path, to: target, overwrite: false)
            } else { return "source contains an unsupported filesystem object: ${child.path}" }
        }
        return ""
    } catch (e: Exception) { return "copy failed: ${e.message}" }
}

private func strictArchiveCommandError(name: String, result: CapturedProcessResult): String {
    if (!result.success) { return "${name} could not run: ${result.error}" }
    if (result.exitCode != 0) { return "${name} failed with exit code ${result.exitCode}: ${firstArchiveDiagnostic(result.stderr, result.stdout)}" }
    if (!result.stderr.trim().isEmpty()) { return "${name} wrote unexpected stderr: ${firstArchiveDiagnostic(result.stderr, "")}" }
    return ""
}
private func firstArchiveDiagnostic(primary: String, secondary: String): String {
    for (source in [primary, secondary]) { for (line in source.lines()) { if (!line.trim().isEmpty()) { return line.trim() } } }
    return "no diagnostic output"
}
private func validateExtractedArchiveLayout(extracted: Path, rootName: String): String {
    try {
        let children = Directory.readFrom(extracted)
        var count: Int64 = 0
        for (child in children) {
            count++
            if (child.isSymbolicLink() || !child.isDirectory() || child.name != rootName) {
                return "Archive must contain exactly the expected top-level directory '${rootName}'."
            }
        }
        if (count != 1) { return "Archive must contain exactly one top-level directory '${rootName}'." }
        return ""
    } catch (e: Exception) { return "Unable to inspect extracted archive layout: ${e.message}" }
}
private func filesHaveSameBytes(left: Path, right: Path): Bool {
    try {
        let leftBytes = File.readFrom(left); let rightBytes = File.readFrom(right)
        if (leftBytes.size != rightBytes.size) { return false }
        for (index in 0..leftBytes.size) { if (leftBytes[index] != rightBytes[index]) { return false } }
        return true
    } catch (e: Exception) { return false }
}
private func pruneArchiveWorkspace(temp: Path, staged: Path, extracted: Path, files: Array<Path>): String {
    try {
        for (path in [staged, extracted]) {
            if (!isPathInsideForFiles(path, temp, false) || FileInfo(path).isSymbolicLink()) { return "Refused unsafe archive workspace cleanup: ${path}" }
            let treeError = validateRecursiveRemovalTree(path)
            if (!treeError.isEmpty()) { return "Refused unsafe archive workspace cleanup: ${treeError}" }
            remove(path, recursive: true)
        }
        for (path in files) { if (!isPathInsideForFiles(path, temp, false)) { return "Refused unsafe helper cleanup: ${path}" }; removeIfExists(path) }
        return ""
    } catch (e: Exception) { return "Unable to clean verified archive workspace before publication: ${e.message}" }
}
private func failArchive(temp: Path, error: String): ArchiveResult {
    let cleanup = cleanupArchiveTemp(temp)
    return if (cleanup.isEmpty()) { ArchiveResult(error) } else { ArchiveResult("${error} Cleanup also failed: ${cleanup}") }
}
private func cleanupArchiveTemp(temp: Path): String {
    try {
        let expectedParent = getTempDirectory().normalize()
        if (!asciiEqualsIgnoreCaseForPe(temp.parent.normalize().toString(), expectedParent.toString())) { return "refused cleanup outside the system temporary directory: ${temp}" }
        let info = FileInfo(temp)
        if (info.isSymbolicLink() || !info.isDirectory()) { return "refused cleanup of non-directory/reparse archive workspace: ${temp}" }
        let marker = temp.join(ARCHIVE_TEMP_MARKER)
        if (!exists(marker) || String.fromUtf8(File.readFrom(marker)) != ARCHIVE_TEMP_MARKER_CONTENT) { return "refused cleanup without archive workspace ownership marker: ${temp}" }
        let treeError = validateRecursiveRemovalTree(temp)
        if (!treeError.isEmpty()) { return "refused cleanup of unsafe archive workspace: ${treeError}" }
        remove(temp, recursive: true)
        return ""
    } catch (e: Exception) { return "unable to remove owned archive workspace '${temp}': ${e.message}" }
}
