package cjdist

import std.collection.ArrayList
import std.fs.*

let OUTPUT_MARKER_NAME = ".cjdist-output"

class CopyItem {
    let source: Path
    let destination: Path
    let kind: String

    public init(source: Path, destination: Path, kind: String) {
        this.source = source
        this.destination = destination
        this.kind = kind
    }
}

class CopyPlan {
    let files: ArrayList<CopyItem>
    let directories: ArrayList<Path>

    public init() {
        this.files = ArrayList<CopyItem>()
        this.directories = ArrayList<Path>()
    }
}

class CopyPlanResult {
    let success: Bool
    let plan: ?CopyPlan
    let error: String

    public init(plan: CopyPlan) {
        this.success = true
        this.plan = Some(plan)
        this.error = ""
    }

    public init(error: String) {
        this.success = false
        this.plan = None
        this.error = error
    }
}

func buildCopyPlan(
    config: DistConfig,
    toolchain: ToolchainInfo,
    buildResult: BuildResult,
    runtimeAnalysis: RuntimeAnalysis,
    projectRoot: Path,
    stagingRoot: Path
): CopyPlanResult {
    let outputDirectory = projectRoot.join(Path(config.outputDir)).normalize()
    if (pathsOverlapForFiles(outputDirectory, stagingRoot)) {
        return CopyPlanResult("Configured output-dir overlaps CJDist's managed staging area: ${config.outputDir}")
    }

    let canonicalProjectRoot: Path
    try {
        canonicalProjectRoot = canonicalize(projectRoot)
    } catch (e: Exception) {
        return CopyPlanResult("Unable to resolve the project root: ${e.message}")
    }

    let plan = CopyPlan()
    let entrySource = projectRoot.join(Path(buildResult.entry)).normalize()
    let entryError = addRegularFile(plan, entrySource, Path(entrySource.fileName), "entry", canonicalProjectRoot)
    if (!entryError.isEmpty()) {
        return CopyPlanResult(entryError)
    }

    let runtimeLeaf = if (toolchain.target == "x86_64-w64-mingw32") {
        "windows_x86_64_cjnative"
    } else {
        return CopyPlanResult("Unsupported Runtime directory mapping for target '${toolchain.target}'.")
    }
    let runtimeDirectory = Path(toolchain.sdkRoot)
        .join("runtime")
        .join("lib")
        .join(runtimeLeaf)
        .normalize()
    for (name in runtimeAnalysis.runtimeDlls) {
        let source = runtimeDirectory.join(name).normalize()
        let error = addRegularFile(plan, source, Path(name), "runtime", canonicalize(runtimeDirectory))
        if (!error.isEmpty()) {
            return CopyPlanResult(error)
        }
    }

    for (configuredPath in config.files.dlls) {
        let relative = Path(configuredPath).normalize()
        let source = projectRoot.join(relative).normalize()
        let error = addRegularFile(plan, source, Path(relative.fileName), "dll", canonicalProjectRoot)
        if (!error.isEmpty()) {
            return CopyPlanResult(error)
        }
    }

    for (configuredPath in config.files.include) {
        let relative = Path(configuredPath).normalize()
        let source = projectRoot.join(relative).normalize()
        let overlapError = rejectManagedInputOverlap(source, outputDirectory, stagingRoot, configuredPath)
        if (!overlapError.isEmpty()) {
            return CopyPlanResult(overlapError)
        }
        let error = addResourceTree(plan, source, relative, "resource", canonicalProjectRoot)
        if (!error.isEmpty()) {
            return CopyPlanResult(error)
        }
    }

    for (configuredPath in config.files.licenses) {
        let relative = Path(configuredPath).normalize()
        let source = projectRoot.join(relative).normalize()
        let overlapError = rejectManagedInputOverlap(source, outputDirectory, stagingRoot, configuredPath)
        if (!overlapError.isEmpty()) {
            return CopyPlanResult(overlapError)
        }
        let error = addResourceTree(plan, source, relative, "license", canonicalProjectRoot)
        if (!error.isEmpty()) {
            return CopyPlanResult(error)
        }
    }
    return CopyPlanResult(plan)
}

private func rejectManagedInputOverlap(
    source: Path,
    outputDirectory: Path,
    stagingRoot: Path,
    configuredPath: String
): String {
    try {
        let info = FileInfo(source)
        if (info.isDirectory() && pathsOverlapForFiles(source, outputDirectory)) {
            return "Configured input contains or overlaps output-dir: ${configuredPath}"
        }
        if (info.isDirectory() && pathsOverlapForFiles(source, stagingRoot)) {
            return "Configured input contains or overlaps CJDist's managed staging area: ${configuredPath}"
        }
    } catch (e: Exception) {
        // The regular validation path below reports missing/inaccessible inputs.
    }
    return ""
}

private func addRegularFile(
    plan: CopyPlan,
    source: Path,
    destination: Path,
    kind: String,
    canonicalAllowedRoot: Path
): String {
    try {
        let info = FileInfo(source)
        if (info.isSymbolicLink()) {
            return "Configured ${kind} source is a symbolic link or reparse point: ${source}"
        }
        if (!info.isRegular()) {
            if (info.isDirectory()) {
                return "Configured ${kind} source must be a file: ${source}"
            }
            return "Configured ${kind} source is not a supported regular file: ${source}"
        }
        let canonicalSource = canonicalize(source)
        if (!isPathInsideForFiles(canonicalSource, canonicalAllowedRoot, true)) {
            return "Configured ${kind} source resolves outside its allowed root: ${source}"
        }
    } catch (e: Exception) {
        return "Configured ${kind} source does not exist or is inaccessible: ${source}"
    }
    return addFileDestination(plan, CopyItem(source, destination.normalize(), kind))
}

private func addResourceTree(
    plan: CopyPlan,
    source: Path,
    destination: Path,
    kind: String,
    canonicalProjectRoot: Path
): String {
    try {
        let info = FileInfo(source)
        if (info.isSymbolicLink()) {
            return "Configured ${kind} source is a symbolic link or reparse point: ${source}"
        }
        let canonicalSource = canonicalize(source)
        if (!isPathInsideForFiles(canonicalSource, canonicalProjectRoot, true)) {
            return "Configured ${kind} source resolves outside the project root: ${source}"
        }
        if (info.isRegular()) {
            return addFileDestination(plan, CopyItem(source, destination.normalize(), kind))
        }
        if (!info.isDirectory()) {
            return "Configured ${kind} source has an unsupported filesystem type: ${source}"
        }

        let directoryError = addDirectoryDestination(plan, destination.normalize())
        if (!directoryError.isEmpty()) {
            return directoryError
        }
        for (child in Directory.readFrom(source)) {
            let error = addResourceTree(
                plan,
                child.path.normalize(),
                destination.join(child.name).normalize(),
                kind,
                canonicalProjectRoot
            )
            if (!error.isEmpty()) {
                return error
            }
        }
        return ""
    } catch (e: Exception) {
        return "Configured ${kind} source does not exist or is inaccessible: ${source}"
    }
}

private func addFileDestination(plan: CopyPlan, item: CopyItem): String {
    let destinationText = item.destination.toString()
    if (asciiEqualsIgnoreCaseForPe(destinationText, OUTPUT_MARKER_NAME) ||
        asciiEqualsIgnoreCaseForPe(destinationText, MANIFEST_FILE_NAME)) {
        return "Distribution path is reserved by CJDist: ${destinationText}"
    }
    for (existing in plan.files) {
        if (asciiEqualsIgnoreCaseForPe(existing.destination.toString(), destinationText)) {
            return "Duplicate distribution file name: ${destinationText}"
        }
        if (isAncestorPathForFiles(existing.destination, item.destination) ||
            isAncestorPathForFiles(item.destination, existing.destination)) {
            return "Distribution file/directory path conflict: ${destinationText}"
        }
    }
    for (directory in plan.directories) {
        if (asciiEqualsIgnoreCaseForPe(directory.toString(), destinationText) ||
            isAncestorPathForFiles(item.destination, directory)) {
            return "Distribution file/directory path conflict: ${destinationText}"
        }
    }
    plan.files.add(item)
    return ""
}

private func addDirectoryDestination(plan: CopyPlan, destination: Path): String {
    let destinationText = destination.toString()
    for (file in plan.files) {
        if (asciiEqualsIgnoreCaseForPe(file.destination.toString(), destinationText) ||
            isAncestorPathForFiles(file.destination, destination)) {
            return "Distribution file/directory path conflict: ${destinationText}"
        }
    }
    for (directory in plan.directories) {
        if (asciiEqualsIgnoreCaseForPe(directory.toString(), destinationText)) {
            return ""
        }
    }
    plan.directories.add(destination)
    return ""
}

func isPathInsideForFiles(path: Path, root: Path, allowEqual: Bool): Bool {
    let pathText = path.normalize().toString()
    let rootText = root.normalize().toString()
    if (asciiEqualsIgnoreCaseForPe(pathText, rootText)) {
        return allowEqual
    }
    let prefix = if (rootText.endsWith(Path.Separator)) {
        rootText
    } else {
        rootText + Path.Separator
    }
    return startsWithAsciiIgnoreCaseForFiles(pathText, prefix)
}

private func pathsOverlapForFiles(left: Path, right: Path): Bool {
    return isPathInsideForFiles(left, right, true) || isPathInsideForFiles(right, left, true)
}

private func isAncestorPathForFiles(ancestor: Path, child: Path): Bool {
    return isPathInsideForFiles(child, ancestor, false)
}

private func startsWithAsciiIgnoreCaseForFiles(value: String, prefix: String): Bool {
    let valueBytes = value.toArray()
    let prefixBytes = prefix.toArray()
    if (valueBytes.size < prefixBytes.size) {
        return false
    }
    for (index in 0..prefixBytes.size) {
        let left = if (valueBytes[index] >= 65 && valueBytes[index] <= 90) {
            valueBytes[index] + 32
        } else {
            valueBytes[index]
        }
        let right = if (prefixBytes[index] >= 65 && prefixBytes[index] <= 90) {
            prefixBytes[index] + 32
        } else {
            prefixBytes[index]
        }
        if (left != right) {
            return false
        }
    }
    return true
}
