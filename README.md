# CJDist

Status: initial release / stable v0.1 scope

Version: v0.1.0

CJDist is a Cangjie native application distribution and verification tool for Windows.
Its intended workflow is to build one Cangjie executable, assemble an explicit
distribution directory, record its contents, and verify that it can start without
depending on the developer's Cangjie SDK environment.

## What CJDist is

CJDist is intended to assemble a Windows native application distribution directory
from explicitly declared inputs:

- one Cangjie `cjnative` executable;
- either the matching dynamic Cangjie Runtime from the build SDK, or a verified
  static-Runtime executable produced by a capable toolchain;
- explicitly declared native DLLs;
- explicitly declared resources and configuration files;
- explicitly declared license and notice files;
- a manifest and SHA-256 file records;
- a clean-environment startup verification result;
- an optional portable ZIP archive that is extracted and reverified before acceptance.

The current source tree implements strict `cjdist.toml` loading, Windows SDK discovery
from the current process `PATH`, CJPM build orchestration, explicit executable-entry
validation, static PE direct-import inspection, same-build-SDK Runtime dependency
mapping, fresh staging, and safe staged publication of explicitly configured files.
It generates a deterministic distribution manifest with per-file SHA-256 records,
strictly verifies that manifest and the exact distribution tree, and runs the configured
startup probe with a PATH that does not contain the Cangjie SDK. It also supports a
standalone verified-directory-to-ZIP workflow and validates static Runtime declarations
against the executable's actual PE imports.

## What CJDist is not

- CJDist is not Docker or a container system.
- CJDist is not an installer generator; its ZIP is a portable archive.
- CJDist is not a wrapper around `cjpm bundle`.
- CJDist does not publish packages to the Cangjie package repository.
- CJDist does not decide whether a DLL may legally be redistributed.
- CJDist does not automatically discover DLLs loaded at runtime.

`cjpm bundle` produces a source package or repository artifact. CJDist is designed
for a final-user native application distribution directory.

## Quick Start

Build the development executable with CJPM's explicit output-name option:

```powershell
cjpm build -o cjdist
```

CJPM 1.0.5 otherwise names a single executable `main.exe` by default. The command
above writes `target/release/bin/cjdist.exe`.

```text
cjdist
cjdist build
cjdist verify <dist-dir>
cjdist archive <dist-dir>
cjdist --help
cjdist --version
```

`cjdist.exe` itself can run without a Cangjie SDK. `verify` and `archive` operate
from a complete distribution and do not require a Cangjie toolchain. `cjdist build`
requires a usable Cangjie SDK and CJPM in the current environment; without `cjpm.exe`
on `PATH`, it fails with `ERROR Toolchain` and exit code `5`.

`build` performs these implemented stages:

1. load and validate `cjdist.toml` from the current working directory;
2. select the first real `cjpm.exe` found in the current process `PATH`;
3. require the official Windows layout `<SDK>\tools\bin\cjpm.exe` and select
   `<SDK>\bin\cjc.exe` from the same SDK;
4. query and conservatively parse both tool versions and the CJC target;
5. run the selected absolute `cjpm.exe` as `cjpm build` in the project root;
6. require `dist.entry` to exist as a regular `.exe` file;
7. run the selected SDK's absolute `third_party\llvm\bin\llvm-objdump.exe -p` and
   parse only descriptors inside its confirmed Import Tables section;
8. match imports against actual files in the selected SDK's target Runtime directory:
   dynamic mode recursively collects the Runtime closure, while static mode fails if any
   SDK Runtime DLL is still imported;
9. build and validate a case-insensitive copy plan for the entry, Runtime closure,
   explicit third-party DLLs, resources, and license/notice files;
10. prepare a fresh, tool-owned staging directory and copy every planned file;
11. record payload sizes and SHA-256 values in a deterministic `cjdist-manifest.json`
    together with the standalone startup contract;
12. strictly parse and validate the manifest, require the exact declared tree, recheck
    every size and SHA-256, and run the startup probe in a controlled child environment;
13. publish only after verification succeeds, preserving the old output on failure.

CJDist does not run `cjpm clean`, execute `envsetup`, modify `PATH`, or rename the
project's build product. The project retains normal CJPM incremental-build behavior.
`build` returns `0` only after build, staging, integrity verification, the clean-environment
startup probe, and publication all succeed. `verify <dist-dir>` is standalone: it uses only
the distribution manifest and does not require the original project or `cjdist.toml`.
`archive <dist-dir>` is deliberately separate from `build`: archive failure cannot make a
correct distribution build invalid, and an existing standalone distribution can be archived.

Exit codes are intentionally compact:

| Code | Meaning |
|---|---|
| `0` | Help, version, or no-argument usage succeeded. |
| `2` | CLI usage error. |
| `4` | `cjdist.toml` loading or validation failed. |
| `5` | Operational, distribution verification, or archive failure. |

## Configuration

CJDist uses `cjdist.toml`, not a `[bundle]` section in `cjpm.toml`. The repository
contains a complete example file. Configuration is loaded into the typed `DistConfig`,
`RuntimeConfig`, `FilesConfig`, and `VerifyConfig` model before any future build work is
allowed to start.

| Field | v0.1 rule | Meaning |
|---|---|---|
| `dist.name` | Required, non-empty string | Distribution/application name. |
| `dist.entry` | Required project-relative path | Explicit executable path. |
| `dist.output-dir` | Required project-relative path | Destination distribution directory. |
| `dist.runtime.mode` | Optional, default `dynamic` | `dynamic` collects the same-SDK Runtime closure; `static` requires the final PE to import no SDK Runtime DLL. |
| `dist.runtime.source` | Optional, default `build-sdk` | Only `build-sdk` is accepted. In static mode it identifies the Runtime set against which the no-import claim is checked. |
| `dist.files.include` | Optional, default `[]` | Files or directories copied recursively while preserving their project-relative layout. |
| `dist.files.dlls` | Optional, default `[]` | Regular files flattened into the distribution root for DLL/executable co-location. |
| `dist.files.licenses` | Optional, default `[]` | Files or directories copied recursively while preserving their project-relative layout. |
| `dist.verify.args` | Optional, default `[]` | Startup arguments, passed directly without a shell. |
| `dist.verify.expected-exit-code` | Optional, default `0` | Expected process exit code. |
| `dist.verify.timeout-ms` | Optional, default `5000` | Between 1 and 300000 ms. |
| `dist.verify.working-directory` | Optional, default `package-root` | Only `package-root` is supported in v0.1. |

Only these tables are accepted: `[dist]`, `[dist.runtime]`, `[dist.files]`, and
`[dist.verify]`. Unknown tables, unknown keys, duplicate tables, duplicate keys, wrong
value types, malformed input, and unsupported values are errors; they are never ignored.

### Supported TOML subset

The Cangjie 1.0.5 standard library installed for this project does not expose a TOML
parser. CJDist therefore uses a deliberately narrow, fail-closed parser for this schema;
it is not a general TOML implementation.

Supported syntax is limited to:

- the four tables listed above;
- bare schema keys;
- double-quoted basic strings, with `\"`, `\\`, `\n`, `\r`, and `\t` escapes;
- decimal integers with an optional leading minus sign;
- single-line or multi-line arrays of double-quoted strings, including a trailing comma;
- blank lines, spaces/tabs, and `#` comments outside strings.

Unsupported TOML features, including quoted or dotted keys, inline tables, arrays of
tables, nested arrays, literal strings, multiline strings, floats, booleans, dates,
integer base prefixes/underscores, and Unicode escape syntax, are rejected. This list is
an implementation boundary, not a claim about the full TOML specification.

### Dynamic Runtime example

```toml
[dist.runtime]
mode = "dynamic"
source = "build-sdk"
```

Dynamic mode analyzes the executable and copies the required Cangjie Runtime DLL
closure from the same SDK used for the build. It is the CJDist 0.1.0 release baseline
and was validated with Cangjie SDK/CJPM 1.0.5 and 1.2.0 on Windows x64.

### Static Cangjie Runtime example

```toml
[dist.runtime]
mode = "static"
source = "build-sdk"
```

The project/toolchain must produce the static-Runtime executable; CJDist does not add
`--static` or edit `cjpm.toml`. This mode was validated with Cangjie SDK/CJPM 1.2.0 on
Windows x64. Cangjie 1.0.5 static mode is not claimed. Static refers only to Cangjie
Runtime linkage and does not imply a fully static or single-file Windows application.

### Path policy

Every value in `dist.entry`, `dist.output-dir`, `dist.files.include`,
`dist.files.dlls`, and `dist.files.licenses` must be non-empty and project-relative.
CJDist uses Windows-aware `std.fs.Path` normalization and a bounded synthetic project
root to detect escapes. Drive paths, drive-relative paths such as `C:foo`, UNC/rooted
paths, NTFS stream syntax, `.`, and paths that normalize outside the project root are
rejected. Configuration validation does not require the referenced files to exist yet.

After toolchain discovery, CJPM build, and entry validation succeed, `cjdist build`
prints output in this form:

```text
OK    Config    cjdist.toml loaded and validated.
OK    Toolchain    Cangjie SDK 1.0.5 / x86_64-w64-mingw32 (CJPM 1.0.5)
OK    Build    cjpm build completed successfully.
OK    Entry    target\release\bin\main.exe
OK    PE    analyzed executable imports.
OK    Runtime    2 SDK Runtime DLLs required.
      libcangjie-runtime.dll
      libboundscheck.dll
OK    Manifest    generated cjdist-manifest.json.
OK    Hash    SHA-256 recorded for 6 files.
OK    Staging    distribution files prepared.
OK    Files    5 configured and required files published to dist\MyApp.
OK    Verify    startup probe completed successfully in the clean environment.
CJDist build completed successfully.
```

The command then returns `0`. Missing, unreadable, malformed, or invalid configuration
prints an `ERROR Config` diagnostic to stderr and returns `4`. Toolchain, child-process,
CJPM build, entry, copy-plan, staging, and publication failures print an area-specific
error and return `5`. CJPM/CJC diagnostics are preserved rather than rewritten as
CJDist diagnostics.

### Distribution layout and ownership

The configured entry keeps its actual filename in the distribution root. Runtime DLLs
from the selected build SDK and explicitly declared `dist.files.dlls` are also placed in
that root. Resource and license inputs preserve their project-relative paths; directory
inputs are traversed recursively, including empty directories. Symbolic links and Windows
reparse points are rejected rather than followed.

CJDist first validates the complete copy plan using Windows ASCII case-insensitive
destination comparisons. Conflicting basenames or file/directory paths fail before any
staging copy begins. PE `nonRuntimeImports` are recorded but are not treated as a list of
third-party files that must be copied.

Fresh staging lives under the tool-owned `.cjdist\staging` area. Every staging directory
and the staging root have exact ownership markers. A published directory has the minimal
`.cjdist-output` marker; this marker is not a manifest. CJDist refuses to replace an
existing output path without the valid marker, or if a recursive-cleanup candidate
contains a filesystem link or reparse point. Replacement uses no-overwrite directory
renames: the old owned output is first preserved under the staging root, the completed
staging directory is published, and the old backup is removed only afterward. This is
safe staged publication, not a claim of fully atomic replacement.

### Manifest and SHA-256

`cjdist-manifest.json` uses schema version `1` and records the CJDist version,
application name and entry, dynamic or static Runtime mode, CJC/CJPM versions, target, required
empty/resource directories, startup arguments/expected exit/timeout/working-directory,
and the sorted payload file list. Every file record contains
its distribution-relative path, copy-plan kind, byte size, and lowercase SHA-256 value.
Paths use `/` in the manifest and never include the project root, SDK root, staging path,
or another development-machine absolute path.

The ownership marker is recorded as `metadata`. The manifest deliberately does not hash
or list itself, avoiding self-referential hash generation. Directories are recorded
separately and are not hashed. File and directory records use deterministic UTF-8 byte
ordering, and the manifest contains no timestamp.

Cangjie SDK 1.0.5 does not provide the project with a usable JSON serialization module,
so CJDist uses a narrow JSON serializer for this fixed schema. On Windows, SHA-256 is
currently calculated by the absolute system Windows PowerShell executable. CJDist runs a
fixed `-NoProfile -NonInteractive` script, explicitly loads
`Microsoft.PowerShell.Utility`, passes each file as a `LiteralPath` parameter, and accepts
only exactly 64 hexadecimal output characters. A hash/process/format failure prevents
publication and leaves the previous owned distribution unchanged.

### Strict distribution verification

`cjdist verify <dist-dir>` uses a narrow, fail-closed JSON parser for CJDist schema 1.
Malformed JSON, duplicate or unknown keys, missing or wrongly typed fields, invalid
escapes, unsupported schema versions, and trailing data are rejected. Semantic checks
cover safe normalized relative paths, known file kinds, one exact entry, the ownership
marker, case-insensitive uniqueness, file/directory conflicts, sizes, and SHA-256 syntax.

The verifier rejects symlinks, junctions, and reparse points; requires every declared
file and explicit empty directory; and rejects undeclared files or directories. It then
checks size before recomputing each payload hash. Only after integrity passes does it run
the manifest entry from the package root. Arguments are passed as an array without a
shell. Stdout and stderr go to separate CJDist-owned temporary files to avoid pipe
deadlock; timeout forces termination and failed probes show capped diagnostics.

The child inherits a conservative set of ordinary Windows variables, while `PATH` is
rebuilt as distribution root, Windows `System32`, and the Windows directory. It does not
contain the SDK, SDK Runtime, `.cjpm\bin`, or `CANGJIE_HOME`. The probe demonstrates that
the configured startup scenario is portable; it does not exercise every feature or
runtime path in an application.

SHA-256 records provide distribution integrity checking, not publisher authenticity,
tamper-proof signatures, code signing, or protection against an attacker who changes
both payload and manifest. Digital signing is a future concern.

### Portable ZIP archives

`cjdist archive <dist-dir>` first runs the complete shared distribution verification,
including the configured startup probe. It derives an ASCII archive root from
`application.name`: ASCII letters, digits, `-`, `_`, and `.` are retained; every other
run becomes `-`; leading/trailing `-` and `.` are removed; the base is limited to 64
bytes and falls back to `application`. The suffix is always `-windows-x64`.

For example, `My App` produces `My-App-windows-x64.zip` beside, never inside, the
distribution directory. Existing archives are never overwritten. The ZIP contains one
directory named `My-App-windows-x64/`, not loose files at its root.

CJDist stages a fresh copy, invokes the absolute system Windows PowerShell with
`-NoProfile -NonInteractive`, passes paths as script parameters, creates the ZIP, expands
it into a fresh owned temporary directory, checks the single-root layout and byte-identical
manifest, and runs the same strict distribution verifier on the extracted directory.
Only then is the ZIP published. Its SHA-256 is printed as `ArchiveHash`; v0.1 does not
create a sidecar file or write the archive hash into the distribution manifest.

Windows PowerShell 5.1 `Compress-Archive`/`Expand-Archive` was tested with spaces,
nested resources, `.cjdist-output`, and explicit empty directories; all were preserved.
The implementation inherits the platform cmdlets' format and size limitations. Any
future cmdlet behavior that drops a declared item is caught by extraction verification
and fails closed.

### Static Cangjie Runtime mode

CJDist does not edit `cjpm.toml` or add `--static`. The project and selected toolchain
must produce the static executable. When `runtime.mode = "static"`, CJDist analyzes the
final PE against the selected build SDK's Runtime directory and fails if it still imports
an SDK Runtime DLL. No SDK Runtime files are copied, `runtime` file records are forbidden
in a static manifest, and the normal clean-environment startup verification remains
mandatory. Explicit third-party `dist.files.dlls` remains valid because static refers
only to Cangjie Runtime linkage, not to every external dependency.

Windows static mode was validated with Cangjie/CJPM 1.2.0. It is capability-checked by
PE imports and startup behavior rather than hard-coded to exactly version 1.2.0. Cangjie
1.0.5 remains the primary dynamic baseline and is not claimed to support Windows static.

## Implemented

- strict configuration parsing and validation;
- first-match `PATH` toolchain discovery for the official Windows SDK layout;
- same-SDK CJC selection and conservative version/target parsing;
- Windows x64 target enforcement (`x86_64-w64-mingw32`);
- direct absolute-executable CJPM build orchestration;
- deadlock-resistant stdout/stderr capture using separate temporary files;
- configured entry existence, regular-file, and `.exe` validation;
- static PE direct-import inspection with same-SDK `llvm-objdump`;
- recursive, case-insensitive Runtime dependency mapping against actual files in the
  selected build SDK's Runtime directory;
- fresh, uniquely created tool-owned staging directories;
- same-SDK Runtime DLL and explicit third-party DLL collection;
- recursive resource and explicit license/notice copying;
- case-insensitive copy-plan conflict detection and safe staged publication;
- deterministic distribution manifest generation;
- per-file size and SHA-256 recording for every managed payload file;
- strict manifest parsing and semantic/internal-consistency validation;
- exact distribution tree, size, and SHA-256 verification;
- standalone and pre-publication clean-environment startup verification;
- portable ZIP generation with extraction, exact-layout checks, and full re-verification;
- static Cangjie Runtime declaration validation with no Runtime collection.

Tested on Windows x64 with:

- Cangjie SDK/CJPM 1.0.5: dynamic build, package, verify, and archive baseline;
- Cangjie SDK/CJPM 1.2.0: CJDist compilation, dynamic mode, and static Runtime mode.

The repeatable release-readiness entry point is:

```powershell
.\scripts\verify.ps1 -Sdk <cangjie-1.0.5-sdk-root>
```

Passing `-StaticSdk <cangjie-1.2-sdk-root>` additionally runs the 1.2 compilation,
dynamic-mode, and static-mode compatibility tests. The optional SDK is not required for
the 1.0.5 release baseline.

## Still not implemented

- installer generation;
- code signing;
- automatic dynamic DLL tracing.

## v0.1 boundaries

The v0.1 target is Windows x64, one `cjnative` executable, verified dynamic or static
Cangjie Runtime linkage, explicit files, a fresh staging directory, manifest/SHA-256
records, a controlled startup probe, and an optional verified ZIP archive.

Installers, release upload, source-package publishing, containers,
dependency management, SBOM generation, automatic license generation, automatic
dynamic-load tracing, GUI support, and Linux/macOS are
outside the v0.1 scope.

Static PE import inspection does not guarantee discovery of DLLs loaded with
`LoadLibrary`, delay/dynamic-loading paths, plug-in systems, or configuration at runtime.
Third-party DLLs remain explicitly declared through `dist.files.dlls`; CJDist does not
search `System32`, `PATH`, the current directory, or the disk to resolve non-Runtime imports.
CJDist copies only explicitly configured third-party files and does not determine whether
a third-party DLL may legally be redistributed.

## License

CJDist is licensed under the Apache License 2.0. See `LICENSE`.

Release archives that include Cangjie Runtime components carry the original Cangjie SDK
license and open-source notice materials separately under `licenses/cangjie/`. Those
materials are not the CJDist project license; `THIRD_PARTY_NOTICES.txt` is only an index
to the original bundled materials.
