# pdshell — Architecture & Design Document

> Version 2.1.0

---

## 1. Principle-to-Implementation Mapping

| Principle              | Where implemented                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------ |
| Dependency Inversion   | `_resolveStrategy` / `_mergeStrategy` params; `FileProcessStrategy` contract         |
| Pipeline Dataflow      | `\|>` throughout; all stages are `Context → Context`                                 |
| Layered Architecture   | `pdshells`: subdirs → common → default; `mk-pdshell`: 7-stage pipeline               |
| Incremental Mode       | Context grows per stage; never reset mid-pipeline                                    |
| Strategy Management    | `resolveStrategy`, `mergeStrategy`, `FileProcessStrategy` first-class objects        |
| State Machine          | `ContextPhase` enum; `validate.fn-assertPhase` at each stage entry                   |
| Lifecycle Management   | 5 hook phases with guaranteed ordering and labelled shellHook sections               |
| Boundary Clarity       | Public: `mkDevShell`, loader output; Internal: `validate`, `pipeline`, `layer`, `fs` |
| Data-Driven            | All behaviour parameterised; protocol constants replace bare string literals         |
| Communication Protocol | `Context` is the typed envelope; `LayerResult`/`FileResult` are typed outputs        |
| Plugin / Hot-swap      | `combinFrom` = composable plugins; strategies injectable via named params            |

---

## 2. Module Dependency Graph

```
pdshells.nix
    │
    ├── mk-pdshell.nix
    │       ├── validate          (contracts)
    │       ├── resolveStrategy   (pluggable)
    │       ├── extractor         (pure)
    │       ├── mergeStrategy     (pluggable)
    │       ├── hookComposer      (pure)
    │       ├── pipeline          (orchestrator)
    │       └── protocols         (HookPhase, HookFnField, ContextPhase, ShellKey)
    │
    ├── validate   (local contracts)
    ├── naming     (pure)
    ├── fs         (pure path ops)
    └── layer      (orchestrator)
            ├── FileProcessStrategy  (pluggable)
            ├── CommonStrategy       (plugin)
            └── DefaultStrategy      (plugin)
```

---

## 3. Data Flow

### mk-pdshell.nix

```
args  (caller input)
  │
  ▼  mkContext
Context { phase=INIT, args, resolvedCombin=[], extractedHooks=[], mergedInputs={},
          composedHooks={}, mkShellParams={} }
  │
  ▼  pipeline.fn-init           → phase = INIT
  │
  ▼  pipeline.fn-resolve        → phase = RESOLVE
  │                               resolvedCombin = [validated attrset, ...]
  │
  ▼  pipeline.fn-extract        → phase = EXTRACT
  │                               extractedHooks = [{ preInputsHook, postInputsHook,
  │                                                   preShellHook, postShellHook,
  │                                                   shellHook }, ...]
  │
  ▼  pipeline.fn-merge          → phase = MERGE
  │                               mergedInputs = { buildInputs, nativeBuildInputs }
  │
  ▼  pipeline.fn-compose        → phase = COMPOSE
  │                               composedHooks = { preInputs, postInputs,
  │                                                  preShell, postShell,
  │                                                  inheritedShell }
  │
  ▼  pipeline.fn-build          → phase = BUILD
  │                               mkShellParams = { name, buildInputs,
  │                                                  nativeBuildInputs, shellHook }
  │
  ▼  pipeline.fn-exec           → phase = EXEC
                                  pkgs.mkShell derivation
```

### pdshells.nix (per directory)

```
currentPath
  │
  ▼  validate.fn-assertFileExists → validPath
  │
  ▼  layer.fn-processDirectory (validPath, basePath, path, suffix)
  │
  ▼  layer.fn-initialContext     → LayerContext { phase=SCAN }
  │
  ▼  validate.fn-assertStructuralValidation
  │
  ▼  layer.fn-processSubDirs     → phase = SUBDIRS
  │                                subDirsAttrs = { flatShells, variantsTree, shellNames }
  │                                (recursive: calls fn-processDirectory for each subdir)
  │
  ▼  layer.fn-processCommonAttrs → phase = COMMON
  │                                commonAttrs = { flatShells, variantsTree, shellNames }
  │
  ▼  layer.fn-processDefaultAttrs → phase = DEFAULT
  │                                 defaultAttrs = { flatShells, variantsTree, shellNames }
  │
  ▼  validate.fn-assertDefaultAttrsConflicts
  │
  ▼  phase = DONE
  │
  ▼  LayerResult { path, flatShells, variantsTree, shellNames }
```

---

## 4. Protocol Definitions

### HookPhase (mk-pdshell.nix)

Field names present on every normalised hook-config attrset.
Used as keys when reading from `extractedHooks` lists.

```
PRE_INPUTS  = "preInputsHook"
POST_INPUTS = "postInputsHook"
PRE_SHELL   = "preShellHook"
POST_SHELL  = "postShellHook"
SHELL       = "shellHook"
```

### HookFnField (mk-pdshell.nix)

Parallel structure to `HookPhase`. Field names for the optional dynamic hook
functions supplied by the caller.

```
PRE_INPUTS  = "preInputsHookFn"
POST_INPUTS = "postInputsHookFn"
PRE_SHELL   = "preShellHookFn"
POST_SHELL  = "postShellHookFn"
```

### ContextPhase (mk-pdshell.nix)

```
INIT → RESOLVE → EXTRACT → MERGE → COMPOSE → BUILD → EXEC
```

### AttrType (pdshells.nix)

```
Default — from default.nix; file base is NOT part of the shell name
Common  — from any other .nix; file base IS part of the shell name
```

---

## 5. Strategy Contracts

### Resolve Strategy

```
entry:attrset  →  resolved-config:attrset
```

Validated by `validate.fn-assertCombinEntry` after resolution.

### Merge Strategy

```
base:[pkg]  →  extracted:[pkg]  →  merged:[pkg]
```

Deduplication policy is the strategy's responsibility.

### FileProcessStrategy

```nix
{
  attrType              : AttrType
  targetField           : string              # LayerContext field to update
  fn-getFileList        : path → [string]     # which files to process
  fn-getSubVariantsTree : LayerContext → attrset  # visible to the imported file
  fn-aggregateVariantsTree : [FileResult] → attrset
  fn-validationContext  : path → string       # error message prefix
}
```

---

## 6. Key Design Decisions (v2.1)

### Stage 5: no mk helper

The original v2.0 introduced an `mk` helper to reduce repetition across the four
hook phases. The helper took `phase`, `fnField`, and `customField` as arguments —
but in the default case all three resolved to the same string value (e.g.
`"preInputsHook"`). This hid the fact that they play **different semantic roles**:

| Arg           | Role                                          | Source                  |
| ------------- | --------------------------------------------- | ----------------------- |
| `hookName`    | Section label; key to look up inherited hooks | `HookPhase.*`           |
| `fnFieldName` | Key for the optional Fn in args               | `HookFnField.*`         |
| `customStr`   | The caller's string hook                      | `args.${HookPhase.*}`   |
| `fn`          | The caller's dynamic Fn                       | `args.${HookFnField.*}` |

v2.1 restores the explicit per-phase blocks using `HookPhase.*` and `HookFnField.*`
constants, making every argument's role immediately visible and preventing future
confusion if phase names and fn-field names ever diverge.

### \_mkShellStripKeys includes name and extension-point keys

`ShellKey.name` is stripped so `fn-build` can assign it exactly once in the `//`
merge, avoiding silent duplicate-key shadowing.

`ShellKey._resolveStrategy` and `ShellKey._mergeStrategy` are stripped so that
user-injected strategy functions never leak into `pkgs.mkShell`.

### validPath forwarding in fn-processMain

`validate.fn-assertFileExists` returns the validated path. v2.0 piped this result
but then discarded it, passing the original `currentPath` to `fn-processDirectory`.
v2.1 forwards `validPath` — the assertion result — ensuring the validated value is
actually used.

### fn-processDirectory signature

v2.0 accepted a `ctx` parameter but immediately discarded it (building a fresh
context via `fn-initialContext`). Only `ctx.suffix` was used. v2.1 replaces `ctx`
with an explicit `suffix` parameter, making the function signature honest.

### Global uniqueness is now strictly evaluated

v2.0 used a `let` binding that was never forced. v2.1 uses `assert` with `lib.seq`
to guarantee the uniqueness check always runs before the shells are returned.

---

## 7. Error Taxonomy

| Code                      | Module              | Cause                                     |
| ------------------------- | ------------------- | ----------------------------------------- |
| `VALIDATION FAILED`       | validate            | Type mismatch on a boundary value         |
| `HOOK CONTRACT VIOLATION` | validate            | Hook Fn returned wrong type               |
| `PHASE VIOLATION`         | validate            | Stage called out of order                 |
| `INVALID COMBIN ENTRY`    | validate            | combinFrom entry has no shell keys        |
| `INVALID STRUCTURE`       | validate (pdshells) | Imported file did not return attrset      |
| `NAMING CONFLICT`         | validate (pdshells) | Two shells resolved to the same name      |
| `KEY COLLISION`           | validate (pdshells) | defaultAttrs conflicts with existing tree |
| `STRUCTURAL AMBIGUITY`    | validate (pdshells) | Same base name for file and directory     |
| `EMPTY DIRECTORY`         | validate (pdshells) | Directory has no .nix files or sub-dirs   |
| `PATH NOT FOUND`          | validate (pdshells) | devDir doesn't exist                      |
