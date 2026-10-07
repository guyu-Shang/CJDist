package cjdist

import std.collection.ArrayList
import std.fs.*

let MANIFEST_FILE_NAME = "cjdist-manifest.json"

class ManifestFile {
    let path: String
    let kind: String
    let size: Int64
    let sha256: String

    public init(path: String, kind: String, size: Int64, sha256: String) {
        this.path = path
        this.kind = kind
        this.size = size
        this.sha256 = sha256
    }
}

class ManifestVerify {
    let args: Array<String>
    let expectedExitCode: Int64
    let timeoutMs: Int64
    let workingDirectory: String

    public init(args: Array<String>, expectedExitCode: Int64, timeoutMs: Int64, workingDirectory: String) {
        this.args = args
        this.expectedExitCode = expectedExitCode
        this.timeoutMs = timeoutMs
        this.workingDirectory = workingDirectory
    }
}

class Manifest {
    let schemaVersion: Int64
    let cjdistVersion: String
    let applicationName: String
    let entry: String
    let runtimeMode: String
    let cjcVersion: String
    let cjpmVersion: String
    let target: String
    let verify: ManifestVerify
    let files: Array<ManifestFile>
    let directories: Array<String>

    public init(
        applicationName: String,
        entry: String,
        runtimeMode: String,
        toolchain: ToolchainInfo,
        verify: ManifestVerify,
        files: Array<ManifestFile>,
        directories: Array<String>
    ) {
        this.schemaVersion = 1
        this.cjdistVersion = CJDIST_VERSION
        this.applicationName = applicationName
        this.entry = entry
        this.runtimeMode = runtimeMode
        this.cjcVersion = toolchain.cjcVersion
        this.cjpmVersion = toolchain.cjpmVersion
        this.target = toolchain.target
        this.verify = verify
        this.files = files
        this.directories = directories
    }

    public init(
        schemaVersion: Int64,
        cjdistVersion: String,
        applicationName: String,
        entry: String,
        runtimeMode: String,
        cjcVersion: String,
        cjpmVersion: String,
        target: String,
        verify: ManifestVerify,
        files: Array<ManifestFile>,
        directories: Array<String>
    ) {
        this.schemaVersion = schemaVersion
        this.cjdistVersion = cjdistVersion
        this.applicationName = applicationName
        this.entry = entry
        this.runtimeMode = runtimeMode
        this.cjcVersion = cjcVersion
        this.cjpmVersion = cjpmVersion
        this.target = target
        this.verify = verify
        this.files = files
        this.directories = directories
    }
}

class ManifestResult {
    let success: Bool
    let hashedFileCount: Int64
    let error: String

    public init(hashedFileCount: Int64) {
        this.success = true
        this.hashedFileCount = hashedFileCount
        this.error = ""
    }

    public init(error: String) {
        this.success = false
        this.hashedFileCount = 0
        this.error = error
    }
}

private class ManifestCandidate {
    let path: Path
    let kind: String

    public init(path: Path, kind: String) {
        this.path = path
        this.kind = kind
    }
}

func generateDistributionManifest(
    config: DistConfig,
    toolchain: ToolchainInfo,
    buildResult: BuildResult,
    plan: CopyPlan,
    stagingDirectory: Path,
    hashScript: Path
): ManifestResult {
    let powershellResult = resolveSystemPowerShell()
    if (!powershellResult.success) {
        return ManifestResult(powershellResult.error)
    }
    let powershellPath = powershellResult.hash

    let candidates = ArrayList<ManifestCandidate>()
    for (item in plan.files) {
        candidates.add(ManifestCandidate(item.destination.normalize(), item.kind))
    }
    candidates.add(ManifestCandidate(Path(OUTPUT_MARKER_NAME), "metadata"))
    let sortedCandidates = candidates.toArray()
    sortManifestCandidates(sortedCandidates)

    let files = ArrayList<ManifestFile>()
    for (candidate in sortedCandidates) {
        let relativePath = manifestPath(candidate.path)
        let absolutePath = stagingDirectory.join(candidate.path).normalize()
        try {
            let info = FileInfo(absolutePath)
            if (info.isSymbolicLink() || !info.isRegular()) {
                return ManifestResult("Manifest payload is not a regular file: ${relativePath}")
            }
            let hashResult = calculateFileSha256(powershellPath, hashScript, absolutePath)
            if (!hashResult.success) {
                return ManifestResult("Unable to hash '${relativePath}': ${hashResult.error}")
            }
            files.add(ManifestFile(relativePath, candidate.kind, info.size, hashResult.hash))
        } catch (e: Exception) {
            return ManifestResult("Unable to inspect manifest payload '${relativePath}': ${e.message}")
        }
    }

    let directories = Array<String>(plan.directories.size, repeat: "")
    for (index in 0..plan.directories.size) {
        let relative = plan.directories[index]
        let absolute = stagingDirectory.join(relative).normalize()
        try {
            let info = FileInfo(absolute)
            if (info.isSymbolicLink() || !info.isDirectory()) {
                return ManifestResult("Manifest directory is not a normal directory: ${manifestPath(relative)}")
            }
        } catch (e: Exception) {
            return ManifestResult("Unable to inspect manifest directory '${manifestPath(relative)}': ${e.message}")
        }
        directories[index] = manifestPath(relative)
    }
    sortManifestPaths(directories)

    let entryName = Path(buildResult.entry).normalize().fileName
    let manifest = Manifest(
        config.name,
        entryName,
        config.runtime.mode,
        toolchain,
        ManifestVerify(
            config.verify.args,
            config.verify.expectedExitCode,
            config.verify.timeoutMs,
            config.verify.workingDirectory
        ),
        files.toArray(),
        directories
    )
    let manifestPathOnDisk = stagingDirectory.join(MANIFEST_FILE_NAME)
    try {
        if (exists(manifestPathOnDisk)) {
            return ManifestResult("Reserved manifest destination already exists in staging.")
        }
        File.writeTo(manifestPathOnDisk, serializeManifest(manifest).toArray())
        let info = FileInfo(manifestPathOnDisk)
        if (info.isSymbolicLink() || !info.isRegular()) {
            return ManifestResult("Generated manifest is not a regular file.")
        }
    } catch (e: Exception) {
        return ManifestResult("Unable to generate ${MANIFEST_FILE_NAME}: ${e.message}")
    }
    return ManifestResult(files.size)
}

func serializeManifest(manifest: Manifest): String {
    let builder = StringBuilder()
    builder.append("{\n")
    builder.append("  \"schemaVersion\": ${manifest.schemaVersion},\n")
    builder.append("  \"cjdistVersion\": \"${jsonEscape(manifest.cjdistVersion)}\",\n")
    builder.append("  \"application\": {\n")
    builder.append("    \"name\": \"${jsonEscape(manifest.applicationName)}\",\n")
    builder.append("    \"entry\": \"${jsonEscape(manifest.entry)}\"\n")
    builder.append("  },\n")
    builder.append("  \"runtime\": {\n")
    builder.append("    \"mode\": \"${jsonEscape(manifest.runtimeMode)}\"\n")
    builder.append("  },\n")
    builder.append("  \"toolchain\": {\n")
    builder.append("    \"cjcVersion\": \"${jsonEscape(manifest.cjcVersion)}\",\n")
    builder.append("    \"cjpmVersion\": \"${jsonEscape(manifest.cjpmVersion)}\",\n")
    builder.append("    \"target\": \"${jsonEscape(manifest.target)}\"\n")
    builder.append("  },\n")
    builder.append("  \"verify\": {\n")
    builder.append("    \"args\": [")
    for (index in 0..manifest.verify.args.size) {
        let comma = if (index + 1 < manifest.verify.args.size) { ", " } else { "" }
        builder.append("\"${jsonEscape(manifest.verify.args[index])}\"${comma}")
    }
    builder.append("],\n")
    builder.append("    \"expectedExitCode\": ${manifest.verify.expectedExitCode},\n")
    builder.append("    \"timeoutMs\": ${manifest.verify.timeoutMs},\n")
    builder.append("    \"workingDirectory\": \"${jsonEscape(manifest.verify.workingDirectory)}\"\n")
    builder.append("  },\n")
    builder.append("  \"directories\": [")
    if (manifest.directories.size > 0) {
        builder.append("\n")
        for (index in 0..manifest.directories.size) {
            let comma = if (index + 1 < manifest.directories.size) { "," } else { "" }
            builder.append("    \"${jsonEscape(manifest.directories[index])}\"${comma}\n")
        }
        builder.append("  ")
    }
    builder.append("],\n")
    builder.append("  \"files\": [")
    if (manifest.files.size > 0) {
        builder.append("\n")
        for (index in 0..manifest.files.size) {
            let file = manifest.files[index]
            let comma = if (index + 1 < manifest.files.size) { "," } else { "" }
            builder.append("    {\n")
            builder.append("      \"path\": \"${jsonEscape(file.path)}\",\n")
            builder.append("      \"kind\": \"${jsonEscape(file.kind)}\",\n")
            builder.append("      \"size\": ${file.size},\n")
            builder.append("      \"sha256\": \"${file.sha256}\"\n")
            builder.append("    }${comma}\n")
        }
        builder.append("  ")
    }
    builder.append("]\n")
    builder.append("}\n")
    return builder.toString()
}

private func sortManifestCandidates(values: Array<ManifestCandidate>): Unit {
    for (left in 0..values.size) {
        var minimum = left
        for (right in (left + 1)..values.size) {
            if (compareManifestText(manifestPath(values[right].path), manifestPath(values[minimum].path)) < 0) {
                minimum = right
            }
        }
        if (minimum != left) {
            let value = values[left]
            values[left] = values[minimum]
            values[minimum] = value
        }
    }
}

private func sortManifestPaths(values: Array<String>): Unit {
    for (left in 0..values.size) {
        var minimum = left
        for (right in (left + 1)..values.size) {
            if (compareManifestText(values[right], values[minimum]) < 0) {
                minimum = right
            }
        }
        if (minimum != left) {
            let value = values[left]
            values[left] = values[minimum]
            values[minimum] = value
        }
    }
}

private func compareManifestText(left: String, right: String): Int64 {
    let leftBytes = left.toArray()
    let rightBytes = right.toArray()
    let limit = if (leftBytes.size < rightBytes.size) { leftBytes.size } else { rightBytes.size }
    for (index in 0..limit) {
        if (leftBytes[index] < rightBytes[index]) { return -1 }
        if (leftBytes[index] > rightBytes[index]) { return 1 }
    }
    if (leftBytes.size < rightBytes.size) { return -1 }
    if (leftBytes.size > rightBytes.size) { return 1 }
    return 0
}

private func manifestPath(path: Path): String {
    let bytes = path.normalize().toString().toArray()
    for (index in 0..bytes.size) {
        if (bytes[index] == 92) {
            bytes[index] = 47
        }
    }
    return String.fromUtf8(bytes)
}

private func jsonEscape(value: String): String {
    let bytes = value.toArray()
    let builder = StringBuilder()
    var chunkStart: Int64 = 0
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (byte == 34 || byte == 92 || byte < 32) {
            if (index > chunkStart) {
                builder.append(value[chunkStart..index])
            }
            if (byte == 34) {
                builder.append("\\\"")
            } else if (byte == 92) {
                builder.append("\\\\")
            } else {
                builder.append("\\u00${hexByte(byte / 16)}${hexByte(byte % 16)}")
            }
            chunkStart = index + 1
        }
    }
    if (chunkStart < bytes.size) {
        builder.append(value[chunkStart..bytes.size])
    }
    return builder.toString()
}

private func hexByte(value: Byte): String {
    let byte = if (value < 10) { value + 48 } else { value - 10 + 97 }
    return String.fromUtf8([byte])
}
