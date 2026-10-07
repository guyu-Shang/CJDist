package cjdist

import std.collection.ArrayList
import std.fs.*

class RuntimeAnalysis {
    let runtimeDlls: Array<String>
    let nonRuntimeImports: Array<String>

    public init(runtimeDlls: Array<String>, nonRuntimeImports: Array<String>) {
        this.runtimeDlls = runtimeDlls
        this.nonRuntimeImports = nonRuntimeImports
    }
}

class RuntimeAnalysisResult {
    let success: Bool
    let analysis: ?RuntimeAnalysis
    let error: String

    public init(analysis: RuntimeAnalysis) {
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

private class RuntimeFile {
    let name: String
    let path: Path

    public init(name: String, path: Path) {
        this.name = name
        this.path = path
    }
}

func mapRuntimeDependencies(
    entryAnalysis: PeAnalysis,
    toolchain: ToolchainInfo
): RuntimeAnalysisResult {
    let runtimeLeaf = if (toolchain.target == "x86_64-w64-mingw32") {
        "windows_x86_64_cjnative"
    } else {
        return RuntimeAnalysisResult("Unsupported Runtime directory mapping for target '${toolchain.target}'.")
    }
    let runtimeDirectory = Path(toolchain.sdkRoot)
        .join("runtime")
        .join("lib")
        .join(runtimeLeaf)
        .normalize()

    try {
        if (!FileInfo(runtimeDirectory).isDirectory()) {
            return RuntimeAnalysisResult("The selected SDK Runtime directory does not exist: ${runtimeDirectory}")
        }
    } catch (e: Exception) {
        return RuntimeAnalysisResult("Unable to access the selected SDK Runtime directory: ${e.message}")
    }

    let runtimeFiles = ArrayList<RuntimeFile>()
    try {
        for (info in Directory.readFrom(runtimeDirectory)) {
            if (!info.isRegular()) {
                continue
            }
            for (existing in runtimeFiles) {
                if (asciiEqualsIgnoreCaseForPe(existing.name, info.name)) {
                    return RuntimeAnalysisResult("The SDK Runtime directory contains duplicate case-insensitive names: ${info.name}")
                }
            }
            runtimeFiles.add(RuntimeFile(info.name, info.path.normalize()))
        }
    } catch (e: Exception) {
        return RuntimeAnalysisResult("Unable to enumerate the selected SDK Runtime directory: ${e.message}")
    }

    let runtimeDlls = ArrayList<String>()
    let nonRuntimeImports = ArrayList<String>()
    let pending = ArrayList<RuntimeFile>()
    addResolvedImports(entryAnalysis.imports, runtimeFiles, runtimeDlls, nonRuntimeImports, pending)

    var index: Int64 = 0
    while (index < pending.size) {
        let runtimeFile = pending[index]
        index++
        let peResult = analyzePeImports(runtimeFile.path, toolchain)
        if (!peResult.success) {
            return RuntimeAnalysisResult("Unable to analyze SDK Runtime DLL '${runtimeFile.name}': ${peResult.error}")
        }
        let analysis = match (peResult.analysis) {
            case Some(value) => value
            case None => return RuntimeAnalysisResult("Runtime PE analysis returned no result for '${runtimeFile.name}'.")
        }
        addResolvedImports(analysis.imports, runtimeFiles, runtimeDlls, nonRuntimeImports, pending)
    }

    return RuntimeAnalysisResult(RuntimeAnalysis(runtimeDlls.toArray(), nonRuntimeImports.toArray()))
}

private func addResolvedImports(
    imports: Array<String>,
    runtimeFiles: ArrayList<RuntimeFile>,
    runtimeDlls: ArrayList<String>,
    nonRuntimeImports: ArrayList<String>,
    pending: ArrayList<RuntimeFile>
): Unit {
    for (importName in imports) {
        let runtimeFile = findRuntimeFile(runtimeFiles, importName)
        match (runtimeFile) {
            case Some(file) =>
                if (!containsAsciiIgnoreCase(runtimeDlls, file.name)) {
                    runtimeDlls.add(file.name)
                    pending.add(file)
                }
            case None =>
                if (!containsAsciiIgnoreCase(nonRuntimeImports, importName)) {
                    nonRuntimeImports.add(importName)
                }
        }
    }
}

private func findRuntimeFile(runtimeFiles: ArrayList<RuntimeFile>, name: String): ?RuntimeFile {
    for (file in runtimeFiles) {
        if (asciiEqualsIgnoreCaseForPe(file.name, name)) {
            return Some(file)
        }
    }
    return None
}
