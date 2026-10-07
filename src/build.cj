package cjdist

import std.env.getWorkingDirectory
import std.fs.*

class BuildResult {
    let success: Bool
    let entry: String
    let error: String

    public init(success: Bool, entry: String, error: String) {
        this.success = success
        this.entry = entry
        this.error = error
    }
}

func buildProject(config: DistConfig, toolchain: ToolchainInfo): BuildResult {
    let projectRoot = getWorkingDirectory()
    let build = runCaptured(toolchain.cjpmPath, ["build"], projectRoot)
    if (!build.success) {
        return BuildResult(false, "", build.error)
    }

    replayProcessOutput(build)
    if (build.exitCode != 0) {
        return BuildResult(false, "", "cjpm build failed with exit code ${build.exitCode}.")
    }

    let relativeEntry = Path(config.entry).normalize()
    if (!asciiEqualsIgnoreCaseForBuild(relativeEntry.extensionName, "exe")) {
        return BuildResult(false, "", "Configured entry is not a Windows .exe file: ${config.entry}")
    }

    let absoluteEntry = projectRoot.join(relativeEntry).normalize()
    try {
        let entryInfo = FileInfo(absoluteEntry)
        if (!entryInfo.isRegular()) {
            if (entryInfo.isDirectory()) {
                return BuildResult(false, "", "Configured entry is a directory, not a file: ${config.entry}")
            }
            return BuildResult(false, "", "Configured entry was not produced: ${config.entry}")
        }
    } catch (e: Exception) {
        return BuildResult(false, "", "Configured entry was not produced: ${config.entry}")
    }

    return BuildResult(true, relativeEntry.toString(), "")
}

private func asciiEqualsIgnoreCaseForBuild(left: String, right: String): Bool {
    let leftBytes = left.toArray()
    let rightBytes = right.toArray()
    if (leftBytes.size != rightBytes.size) {
        return false
    }
    for (index in 0..leftBytes.size) {
        let a = if (leftBytes[index] >= 65 && leftBytes[index] <= 90) {
            leftBytes[index] + 32
        } else {
            leftBytes[index]
        }
        let b = if (rightBytes[index] >= 65 && rightBytes[index] <= 90) {
            rightBytes[index] + 32
        } else {
            rightBytes[index]
        }
        if (a != b) {
            return false
        }
    }
    return true
}
