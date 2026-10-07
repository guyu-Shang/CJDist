package cjdist

import std.env.getWorkingDirectory
import std.fs.*

let STAGING_ROOT_DIRECTORY = ".cjdist\\staging"
let STAGING_ROOT_MARKER = ".cjdist-staging-root"
let STAGING_MARKER_SUFFIX = ".cjdist-staging"
let HASH_SCRIPT_SUFFIX = ".cjdist-sha256.ps1"
let STAGING_ROOT_MARKER_CONTENT = "CJDist managed staging root\n"
let STAGING_MARKER_CONTENT = "CJDist owned staging directory\n"

class DistributionResult {
    let success: Bool
    let area: String
    let outputDirectory: String
    let fileCount: Int64
    let hashedFileCount: Int64
    let error: String

    public init(outputDirectory: String, fileCount: Int64, hashedFileCount: Int64) {
        this.success = true
        this.area = ""
        this.outputDirectory = outputDirectory
        this.fileCount = fileCount
        this.hashedFileCount = hashedFileCount
        this.error = ""
    }

    public init(area: String, error: String) {
        this.success = false
        this.area = area
        this.outputDirectory = ""
        this.fileCount = 0
        this.hashedFileCount = 0
        this.error = error
    }
}

func stageDistribution(
    config: DistConfig,
    toolchain: ToolchainInfo,
    buildResult: BuildResult,
    runtimeAnalysis: RuntimeAnalysis
): DistributionResult {
    let projectRoot = getWorkingDirectory().normalize()
    let outputDirectory = projectRoot.join(Path(config.outputDir)).normalize()
    let stagingRoot = projectRoot.join(Path(STAGING_ROOT_DIRECTORY)).normalize()

    let outputPathError = rejectReparsePathChain(outputDirectory, projectRoot, "output-dir")
    if (!outputPathError.isEmpty()) {
        return DistributionResult("Staging", outputPathError)
    }
    let stagingPathError = rejectReparsePathChain(stagingRoot, projectRoot, "staging root")
    if (!stagingPathError.isEmpty()) {
        return DistributionResult("Staging", stagingPathError)
    }

    let ownershipError = validateExistingOutput(outputDirectory)
    if (!ownershipError.isEmpty()) {
        return DistributionResult("Staging", ownershipError)
    }

    let planResult = buildCopyPlan(
        config,
        toolchain,
        buildResult,
        runtimeAnalysis,
        projectRoot,
        stagingRoot
    )
    if (!planResult.success) {
        return DistributionResult("Files", planResult.error)
    }
    let plan = match (planResult.plan) {
        case Some(value) => value
        case None => return DistributionResult("Files", "Copy-plan validation returned no plan.")
    }

    let stagingRootError = ensureStagingRoot(stagingRoot)
    if (!stagingRootError.isEmpty()) {
        return DistributionResult("Staging", stagingRootError)
    }

    let stagingDirectory: Path
    try {
        stagingDirectory = Directory.createTemp(stagingRoot)
    } catch (e: Exception) {
        return DistributionResult("Staging", "Unable to create a fresh staging directory: ${e.message}")
    }
    let stagingMarker = stagingMarkerPath(stagingDirectory)
    try {
        File.writeTo(stagingMarker, STAGING_MARKER_CONTENT.toArray())
    } catch (e: Exception) {
        try {
            remove(stagingDirectory)
        } catch (ignored: Exception) {
            // The newly created directory is empty; failure is reported below.
        }
        return DistributionResult("Staging", "Unable to mark the fresh staging directory: ${e.message}")
    }

    let copyError = executeCopyPlan(plan, stagingDirectory)
    if (!copyError.isEmpty()) {
        return cleanupAfterFailure(
            "Files",
            copyError,
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            outputDirectory
        )
    }

    let outputMarker = stagingDirectory.join(OUTPUT_MARKER_NAME)
    try {
        File.writeTo(outputMarker, outputMarkerContent().toArray())
    } catch (e: Exception) {
        return cleanupAfterFailure(
            "Staging",
            "Unable to create the distribution ownership marker: ${e.message}",
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            outputDirectory
        )
    }

    let hashScript = stagingRoot.join(stagingDirectory.fileName + HASH_SCRIPT_SUFFIX).normalize()
    try {
        if (exists(hashScript)) {
            return cleanupAfterFailure(
                "Manifest",
                "Refusing to overwrite an unexpected SHA-256 helper script: ${hashScript}",
                stagingDirectory,
                stagingRoot,
                stagingMarker,
                outputDirectory
            )
        }
        File.writeTo(hashScript, SHA256_SCRIPT_CONTENT.toArray())
    } catch (e: Exception) {
        return cleanupAfterFailure(
            "Manifest",
            "Unable to create the SHA-256 helper script: ${e.message}",
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            outputDirectory
        )
    }

    let manifestResult = generateDistributionManifest(
        config,
        toolchain,
        buildResult,
        plan,
        stagingDirectory,
        hashScript
    )
    try {
        removeIfExists(hashScript)
    } catch (e: Exception) {
        // The fixed helper is outside the distribution and is never published.
    }
    if (!manifestResult.success) {
        return cleanupAfterFailure(
            "Manifest",
            manifestResult.error,
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            outputDirectory
        )
    }

    // Verify the fresh staging tree before it can replace a previous successful output.
    let verification = verifyDistribution(stagingDirectory)
    if (!verification.success) {
        match (verification.startup) {
            case Some(result) => reportStartupDiagnostics(result)
            case None => ()
        }
        return cleanupAfterFailure(
            "Verify",
            verification.error,
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            outputDirectory
        )
    }

    let publishError = publishStaging(
        stagingDirectory,
        stagingRoot,
        stagingMarker,
        outputDirectory
    )
    if (!publishError.isEmpty()) {
        return DistributionResult("Staging", publishError)
    }
    return DistributionResult(config.outputDir, plan.files.size, manifestResult.hashedFileCount)
}

private func executeCopyPlan(plan: CopyPlan, stagingDirectory: Path): String {
    try {
        for (relativeDirectory in plan.directories) {
            let directoryError = ensureNormalDirectory(stagingDirectory.join(relativeDirectory).normalize())
            if (!directoryError.isEmpty()) {
                return directoryError
            }
        }
        for (item in plan.files) {
            let destination = stagingDirectory.join(item.destination).normalize()
            if (!isPathInsideForFiles(destination, stagingDirectory, false)) {
                return "Planned destination escapes the staging directory: ${item.destination}"
            }
            let parentError = ensureNormalDirectory(destination.parent)
            if (!parentError.isEmpty()) {
                return parentError
            }
            copy(item.source, to: destination, overwrite: false)
        }
        for (item in plan.files) {
            let destination = stagingDirectory.join(item.destination).normalize()
            let info = FileInfo(destination)
            if (info.isSymbolicLink() || !info.isRegular()) {
                return "Planned destination was not produced as a regular file: ${item.destination}"
            }
        }
        return ""
    } catch (e: Exception) {
        return "Unable to prepare distribution files: ${e.message}"
    }
}

private func ensureStagingRoot(stagingRoot: Path): String {
    let marker = stagingRoot.join(STAGING_ROOT_MARKER)
    try {
        if (exists(stagingRoot)) {
            let info = FileInfo(stagingRoot)
            if (info.isSymbolicLink() || !info.isDirectory()) {
                return "CJDist staging root is not a normal directory: ${stagingRoot}"
            }
            if (!hasExactMarker(marker, STAGING_ROOT_MARKER_CONTENT)) {
                return "Refusing to use an unowned staging root: ${stagingRoot}"
            }
            return ""
        }
        Directory.create(stagingRoot, recursive: true)
        File.writeTo(marker, STAGING_ROOT_MARKER_CONTENT.toArray())
        return ""
    } catch (e: Exception) {
        return "Unable to initialize the CJDist staging root: ${e.message}"
    }
}

private func validateExistingOutput(outputDirectory: Path): String {
    try {
        if (!exists(outputDirectory)) {
            return ""
        }
        let info = FileInfo(outputDirectory)
        if (info.isSymbolicLink() || !info.isDirectory()) {
            return "Refusing to replace an existing path not owned by CJDist: ${outputDirectory}"
        }
        if (!hasExactMarker(outputDirectory.join(OUTPUT_MARKER_NAME), outputMarkerContent())) {
            return "Refusing to replace an existing directory not owned by CJDist: ${outputDirectory}"
        }
        let treeError = validateRecursiveRemovalTree(outputDirectory)
        if (!treeError.isEmpty()) {
            return "Refusing to replace an existing CJDist output with an unsafe filesystem tree: ${treeError}"
        }
        return ""
    } catch (e: Exception) {
        return "Unable to validate the existing output directory: ${e.message}"
    }
}

private func publishStaging(
    stagingDirectory: Path,
    stagingRoot: Path,
    stagingMarker: Path,
    outputDirectory: Path
): String {
    let recheckError = validateExistingOutput(outputDirectory)
    if (!recheckError.isEmpty()) {
        let cleanupError = safeRemoveManagedTree(
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            STAGING_MARKER_CONTENT,
            outputDirectory
        )
        return combineCleanupError(recheckError, cleanupError)
    }

    try {
        let parentError = ensureNormalDirectory(outputDirectory.parent)
        if (!parentError.isEmpty()) {
            throw FSException(parentError)
        }
    } catch (e: Exception) {
        let cleanupError = safeRemoveManagedTree(
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            STAGING_MARKER_CONTENT,
            outputDirectory
        )
        return combineCleanupError("Unable to create the output parent directory: ${e.message}", cleanupError)
    }

    if (!exists(outputDirectory)) {
        try {
            rename(stagingDirectory, to: outputDirectory, overwrite: false)
        } catch (e: Exception) {
            let cleanupError = safeRemoveManagedTree(
                stagingDirectory,
                stagingRoot,
                stagingMarker,
                STAGING_MARKER_CONTENT,
                outputDirectory
            )
            return combineCleanupError("Unable to publish the staged distribution: ${e.message}", cleanupError)
        }
        try {
            removeIfExists(stagingMarker)
        } catch (e: Exception) {
            // The marker is outside the published output and can be cleaned later.
        }
        return ""
    }

    let backup = stagingRoot.join("backup-${stagingDirectory.fileName}").normalize()
    if (exists(backup)) {
        let cleanupError = safeRemoveManagedTree(
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            STAGING_MARKER_CONTENT,
            outputDirectory
        )
        return combineCleanupError("Refusing to overwrite an unexpected publication backup: ${backup}", cleanupError)
    }

    try {
        rename(outputDirectory, to: backup, overwrite: false)
    } catch (e: Exception) {
        let cleanupError = safeRemoveManagedTree(
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            STAGING_MARKER_CONTENT,
            outputDirectory
        )
        return combineCleanupError("Unable to preserve the previous distribution before publication: ${e.message}", cleanupError)
    }

    try {
        rename(stagingDirectory, to: outputDirectory, overwrite: false)
    } catch (e: Exception) {
        var restoreError = ""
        try {
            rename(backup, to: outputDirectory, overwrite: false)
        } catch (restore: Exception) {
            restoreError = " Previous distribution remains at '${backup}' because restoration failed: ${restore.message}"
        }
        let cleanupError = safeRemoveManagedTree(
            stagingDirectory,
            stagingRoot,
            stagingMarker,
            STAGING_MARKER_CONTENT,
            outputDirectory
        )
        return combineCleanupError(
            "Unable to publish the staged distribution: ${e.message}${restoreError}",
            cleanupError
        )
    }

    try {
        removeIfExists(stagingMarker)
    } catch (e: Exception) {
        // The marker is outside the published output and can be cleaned on a later run.
    }
    let backupCleanup = safeRemoveManagedTree(
        backup,
        stagingRoot,
        backup.join(OUTPUT_MARKER_NAME),
        outputMarkerContent(),
        outputDirectory
    )
    if (!backupCleanup.isEmpty()) {
        return "The new distribution was published, but the owned previous-output backup could not be removed: ${backupCleanup}"
    }
    return ""
}

private func cleanupAfterFailure(
    area: String,
    error: String,
    stagingDirectory: Path,
    stagingRoot: Path,
    stagingMarker: Path,
    outputDirectory: Path
): DistributionResult {
    let cleanupError = safeRemoveManagedTree(
        stagingDirectory,
        stagingRoot,
        stagingMarker,
        STAGING_MARKER_CONTENT,
        outputDirectory
    )
    return DistributionResult(area, combineCleanupError(error, cleanupError))
}

// Staging cleanup requires a direct child of the managed staging root, an exact
// ownership marker, and a complete no-reparse scan immediately before removal.
private func safeRemoveManagedTree(
    target: Path,
    stagingRoot: Path,
    marker: Path,
    expectedMarker: String,
    outputDirectory: Path
): String {
    let normalizedTarget = target.normalize()
    let normalizedRoot = stagingRoot.normalize()
    if (normalizedTarget.toString().isEmpty() || normalizedTarget.toString() == ".") {
        return "refused unsafe empty/current-directory cleanup target"
    }
    if (!asciiEqualsIgnoreCaseForPe(normalizedTarget.parent.toString(), normalizedRoot.toString())) {
        return "refused cleanup outside the managed staging root: ${normalizedTarget}"
    }
    if (asciiEqualsIgnoreCaseForPe(normalizedTarget.toString(), normalizedRoot.toString()) ||
        asciiEqualsIgnoreCaseForPe(normalizedTarget.toString(), outputDirectory.parent.normalize().toString())) {
        return "refused cleanup of a protected directory: ${normalizedTarget}"
    }
    try {
        let info = FileInfo(normalizedTarget)
        if (info.isSymbolicLink() || !info.isDirectory()) {
            return "refused cleanup of a non-directory or reparse point: ${normalizedTarget}"
        }
        if (!hasExactMarker(marker, expectedMarker)) {
            return "refused cleanup without a valid ownership marker: ${normalizedTarget}"
        }
        let treeError = validateRecursiveRemovalTree(normalizedTarget)
        if (!treeError.isEmpty()) {
            return "refused cleanup of an unsafe filesystem tree: ${treeError}"
        }
        remove(normalizedTarget, recursive: true)
        if (!isPathInsideForFiles(marker, normalizedTarget, true)) {
            removeIfExists(marker)
        }
        return ""
    } catch (e: Exception) {
        return "unable to clean owned staging data '${normalizedTarget}': ${e.message}"
    }
}

// Shared by staging and archive cleanup. Never recurse through a filesystem
// link: inspect each child before descending into it.
func validateRecursiveRemovalTree(root: Path): String {
    try {
        let rootInfo = FileInfo(root)
        if (rootInfo.isSymbolicLink() || !rootInfo.isDirectory()) {
            return "root is not a normal directory: ${root}"
        }
        for (child in Directory.readFrom(root)) {
            if (child.isSymbolicLink()) {
                return "filesystem link or reparse point found at '${child.path}'"
            }
            if (child.isDirectory()) {
                let nestedError = validateRecursiveRemovalTree(child.path.normalize())
                if (!nestedError.isEmpty()) {
                    return nestedError
                }
            } else if (!child.isRegular()) {
                return "unsupported filesystem object found at '${child.path}'"
            }
        }
        return ""
    } catch (e: Exception) {
        return "unable to inspect '${root}' before recursive removal: ${e.message}"
    }
}

private func hasExactMarker(path: Path, expected: String): Bool {
    try {
        let info = FileInfo(path)
        if (info.isSymbolicLink() || !info.isRegular()) {
            return false
        }
        return String.fromUtf8(File.readFrom(path)) == expected
    } catch (e: Exception) {
        return false
    }
}

private func stagingMarkerPath(stagingDirectory: Path): Path {
    return stagingDirectory.parent.join(stagingDirectory.fileName + STAGING_MARKER_SUFFIX).normalize()
}

private func outputMarkerContent(): String {
    return "CJDist generated output\nversion=${CJDIST_VERSION}\n"
}

private func combineCleanupError(error: String, cleanupError: String): String {
    if (cleanupError.isEmpty()) {
        return error
    }
    return "${error} Cleanup also failed: ${cleanupError}"
}

private func ensureNormalDirectory(path: Path): String {
    try {
        if (exists(path)) {
            let info = FileInfo(path)
            if (info.isSymbolicLink() || !info.isDirectory()) {
                return "Required destination parent is not a normal directory: ${path}"
            }
            return ""
        }
        Directory.create(path, recursive: true)
        return ""
    } catch (e: Exception) {
        return "Unable to create destination directory '${path}': ${e.message}"
    }
}

private func rejectReparsePathChain(path: Path, projectRoot: Path, label: String): String {
    var current = path.normalize()
    let root = projectRoot.normalize()
    if (!isPathInsideForFiles(current, root, false)) {
        return "Configured ${label} is outside the project root: ${path}"
    }
    try {
        while (true) {
            if (exists(current) && FileInfo(current).isSymbolicLink()) {
                return "Refusing ${label} through a symbolic link or reparse point: ${current}"
            }
            if (asciiEqualsIgnoreCaseForPe(current.toString(), root.toString())) {
                return ""
            }
            let parent = current.parent.normalize()
            if (asciiEqualsIgnoreCaseForPe(parent.toString(), current.toString())) {
                return "Unable to prove ${label} remains inside the project root: ${path}"
            }
            current = parent
        }
    } catch (e: Exception) {
        return "Unable to validate the ${label} path: ${e.message}"
    }
    return ""
}
