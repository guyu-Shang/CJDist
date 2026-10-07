package cjdist

import std.env.getWorkingDirectory
import std.fs.Path

let CJDIST_VERSION = "0.1.0"
let EXIT_SUCCESS: Int64 = 0
let EXIT_USAGE: Int64 = 2
let EXIT_CONFIG: Int64 = 4
let EXIT_OPERATIONAL: Int64 = 5

func runCli(args: Array<String>): Int64 {
    if (args.size == 0) {
        printShortUsage()
        return EXIT_SUCCESS
    }

    let command = args[0]
    if (command == "--help" || command == "-h") {
        if (args.size != 1) {
            return usageError("--help does not accept additional arguments.")
        }
        printHelp()
        return EXIT_SUCCESS
    }

    if (command == "--version" || command == "-V") {
        if (args.size != 1) {
            return usageError("--version does not accept additional arguments.")
        }
        println("CJDist ${CJDIST_VERSION}")
        return EXIT_SUCCESS
    }

    if (command == "build") {
        if (args.size != 1) {
            return usageError("build does not accept positional arguments yet.")
        }
        let configResult = loadDistConfig("cjdist.toml")
        if (!configResult.success) {
            reportError("Config", configResult.error)
            return EXIT_CONFIG
        }
        reportOk("Config", "cjdist.toml loaded and validated.")

        let toolchainResult = resolveToolchain()
        if (!toolchainResult.success) {
            reportError("Toolchain", toolchainResult.error)
            return EXIT_OPERATIONAL
        }
        let toolchain = match (toolchainResult.info) {
            case Some(value) => value
            case None => return EXIT_OPERATIONAL
        }
        reportOk(
            "Toolchain",
            "Cangjie SDK ${toolchain.cjcVersion} / ${toolchain.target} (CJPM ${toolchain.cjpmVersion})"
        )

        let config = match (configResult.config) {
            case Some(value) => value
            case None => return EXIT_CONFIG
        }
        let buildResult = buildProject(config, toolchain)
        if (!buildResult.success) {
            reportError("Build", buildResult.error)
            return EXIT_OPERATIONAL
        }
        reportOk("Build", "cjpm build completed successfully.")
        reportOk("Entry", buildResult.entry)

        let entryPath = getWorkingDirectory().join(Path(buildResult.entry)).normalize()
        let peResult = analyzePeImports(entryPath, toolchain)
        if (!peResult.success) {
            reportError("PE", peResult.error)
            return EXIT_OPERATIONAL
        }
        let peAnalysis = match (peResult.analysis) {
            case Some(value) => value
            case None => return EXIT_OPERATIONAL
        }
        reportOk("PE", "analyzed executable imports.")

        let runtimeResult = mapRuntimeDependencies(peAnalysis, toolchain)
        if (!runtimeResult.success) {
            reportError("Runtime", runtimeResult.error)
            return EXIT_OPERATIONAL
        }
        let runtimeAnalysis = match (runtimeResult.analysis) {
            case Some(value) => value
            case None => return EXIT_OPERATIONAL
        }
        if (config.runtime.mode == "static") {
            if (runtimeAnalysis.runtimeDlls.size > 0) {
                reportError(
                    "Runtime",
                    "Static mode was declared, but the executable still imports SDK Runtime DLLs: ${joinRuntimeNames(runtimeAnalysis.runtimeDlls)}"
                )
                return EXIT_OPERATIONAL
            }
            reportOk("Runtime", "static declaration confirmed: no SDK Runtime DLL imports.")
        } else {
            reportOk("Runtime", "${runtimeAnalysis.runtimeDlls.size} SDK Runtime DLLs required.")
            for (dll in runtimeAnalysis.runtimeDlls) {
                println("      ${dll}")
            }
        }

        let distribution = stageDistribution(config, toolchain, buildResult, runtimeAnalysis)
        if (!distribution.success) {
            reportError(distribution.area, distribution.error)
            return EXIT_OPERATIONAL
        }
        reportOk("Manifest", "generated ${MANIFEST_FILE_NAME}.")
        reportOk("Hash", "SHA-256 recorded for ${distribution.hashedFileCount} files.")
        reportOk("Staging", "distribution files prepared.")
        reportOk("Files", "${distribution.fileCount} configured and required files published to ${distribution.outputDirectory}.")
        reportOk("Verify", "startup probe completed successfully in the clean environment.")
        println("CJDist build completed successfully.")
        return EXIT_SUCCESS
    }

    if (command == "verify") {
        if (args.size < 2) {
            return usageError("verify requires <dist-dir>.")
        }
        if (args.size > 2) {
            return usageError("verify accepts exactly one <dist-dir>.")
        }
        let result = verifyDistribution(args[1])
        if (!result.success) {
            reportError("Verify", result.error)
            match (result.startup) {
                case Some(startup) => reportStartupDiagnostics(startup)
                case None => ()
            }
            return EXIT_OPERATIONAL
        }
        reportOk("Manifest", "strict schema and semantic validation passed.")
        reportOk("Integrity", "${result.fileCount} files verified.")
        reportOk("Verify", "startup probe completed successfully.")
        println("Distribution verification passed.")
        return EXIT_SUCCESS
    }

    if (command == "archive") {
        if (args.size < 2) { return usageError("archive requires <dist-dir>.") }
        if (args.size > 2) { return usageError("archive accepts exactly one <dist-dir>.") }
        let result = archiveDistribution(args[1])
        if (!result.success) { reportError("Archive", result.error); return EXIT_OPERATIONAL }
        reportOk("Archive", "${result.archivePath} (${result.rootName}/, ${result.fileCount} payload files reverified).")
        reportOk("ArchiveHash", result.sha256)
        println("Distribution archive created and reverified.")
        return EXIT_SUCCESS
    }

    return usageError("Unknown command: ${command}")
}

private func joinRuntimeNames(values: Array<String>): String {
    let builder = StringBuilder()
    for (index in 0..values.size) {
        if (index > 0) { builder.append(", ") }
        builder.append(values[index])
    }
    return builder.toString()
}

func printShortUsage(): Unit {
    println("CJDist ${CJDIST_VERSION}")
    println("Usage: cjdist <command> [options]")
    println("Run 'cjdist --help' for more information.")
}

func printHelp(): Unit {
    println("CJDist ${CJDIST_VERSION}")
    println("Cangjie native application distribution and verification tool for Windows.")
    println("")
    println("Usage:")
    println("  cjdist")
    println("  cjdist build")
    println("  cjdist verify <dist-dir>")
    println("  cjdist archive <dist-dir>")
    println("  cjdist --help")
    println("  cjdist --version")
    println("")
    println("Commands:")
    println("  build              Build and safely stage configured Windows distribution files.")
    println("  verify <dist-dir>  Strictly verify integrity, exact tree, and configured startup probe.")
    println("  archive <dist-dir> Verify, create a portable ZIP, extract, and reverify it.")
}

func usageError(message: String): Int64 {
    reportError("CLI", message)
    eprintln("Run 'cjdist --help' for usage.")
    return EXIT_USAGE
}
