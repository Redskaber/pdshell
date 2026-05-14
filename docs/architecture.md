# pdshell — Architecture & Design Document

> Version 2.2.0

---

## 1. Principle-to-Implementation Mapping

| Principle              | Where implemented                                                                            |
| ---------------------- | -------------------------------------------------------------------------------------------- |
| Dependency Inversion   | `_resolveStrategy`, `_mergeStrategy`, `_hookComposeStrategy`; `FileProcessStrategy` contract |
| Pipeline Dataflow      | `\|>` throughout; all stages are `Context → Context`                                         |
| Layered Architecture   | `pdshells`: subdirs → common → default; `mk-pdshell`: 7-stage pipeline                       |
| Incremental Mode       | Context grows per stage; never reset mid-pipeline                                            |
| Strategy Management    | `resolveStrategy`, `mergeStrategy`, `hookComposeStrategy`, `FileProcessStrategy` first-class |
| State Machine          | `ContextPhase` enum; `validate.fn-assertPhase` at each stage entry                           |
| Lifecycle Management   | 5 hook phases with guaranteed ordering and labelled shellHook sections                       |
| Boundary Clarity       | Public: `mkDevShell`, loader output; Internal: `validate`, `pipeline`, `layer`, `fs`         |
| Data-Driven            | All behaviour parameterised; protocol constants replace bare string literals                 |
| Communication Protocol | `Context` is the typed envelope; `LayerResult`/`FileResult` are typed outputs                |
| Plugin / Hot-swap      | `combinFrom` = composable plugins; all three strategies injectable via named params          |

---

## 2. Module Dependency Graph

```
pdshells.nix
    │
    ├── mk-pdshell.nix
    │       ├── validate                   (contracts)
    │       ├── resolveStrategy            (pluggable)
    │       ├── extractor                  (pure)
    │       ├── mergeStrategy              (pluggable)
    │       ├── hookComposer               (pure + pluggable default strategy)
    │       ├── pipeline                   (orchestrator)
    │       └── protocols                  (HookPhase, HookFnField, ContextPhase, ShellKey)
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
  │                                                  inheritedShell,
  │                                                  preShell, postShell }
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

## 4. Hook Lifecycle

The assembled `shellHook` sections appear in this guaranteed order:

```
# === PRE-INPUTS HOOK ===       ← before buildInputs activated
# === POST-INPUTS HOOK ===      ← after  buildInputs activated
# === INHERITED SHELLHOOK ===   ← combinFrom shellHooks + top-level shellHook
# === PRE-SHELL HOOK ===        ← just before interactive shell
# === POST-SHELL HOOK ===       ← at shell exit / cleanup
# === FINAL SHELL OVERRIDE ===  ← exec <shell> (only if shell != null)
```

Empty sections are omitted entirely. Non-empty sections are separated by blank lines.

---

## 5. Protocol Definitions

### HookPhase (mk-pdshell.nix)

Keys present on every normalised hook-config attrset.
Used as keys when reading from `extractedHooks` lists.

```
PRE_INPUTS  = "preInputsHook"
POST_INPUTS = "postInputsHook"
PRE_SHELL   = "preShellHook"
POST_SHELL  = "postShellHook"
SHELL       = "shellHook"
```

### HookFnField (mk-pdshell.nix)

Parallel structure to `HookPhase`. Field names for optional dynamic hook
functions supplied by the caller (receive `{ pkgs }`).

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

## 6. Strategy Contracts

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

### Hook Compose Strategy

```
args:attrset  →  in:[hookAttrset]  →  resolvedCombin:[attrset]
  →  { preInputs, postInputs, inheritedShell, preShell, postShell }
```

Default: `hookComposer.fn-defaultComposeStrategy`.
Injected via `_hookComposeStrategy` parameter.

### FileProcessStrategy

```nix
{
  attrType                 : AttrType
  targetField              : string                # LayerContext field to update
  fn-getFileList           : path → suffix → [string]   # which files to process
  fn-getSubVariantsTree    : LayerContext → attrset      # visible to the imported file
  fn-aggregateVariantsTree : [FileResult] → attrset
  fn-validationContext     : path → string               # error message prefix
}
```

---

## 7. Key Design Decisions (v2.2)

### Hook assembly order matches lifecycle documentation

v2.1 assembled sections as `INHERITED → PRE-INPUTS → POST-INPUTS → PRE-SHELL → POST-SHELL`,
contradicting the documented lifecycle order. v2.2 corrects `fn-assemble` to emit:
`PRE-INPUTS → POST-INPUTS → INHERITED → PRE-SHELL → POST-SHELL`.

### `_hookComposeStrategy` — third injectable strategy

v2.1 inlined per-phase composition directly in `pipeline.fn-compose`. v2.2 extracts this
into `hookComposer.fn-defaultComposeStrategy` and exposes it as `_hookComposeStrategy`.
This makes hook composition independently testable and replaceable without touching the
pipeline orchestrator. The default strategy is behaviourally identical to v2.1.

### `fn-getFileList` now receives suffix

v2.1's `CommonStrategy.fn-getFileList` called `fs.fn-getAttrsFiles` which used the
module-level `fs.default-nixSuffix` constant, ignoring the runtime `suffix` parameter.
v2.2 threads `ctx.suffix` through `fn-execute` into every strategy call.

### `shell` override is variant-level, not top-level-only

The prior claim that `shell` is "only honoured at the top level" was imprecise.
`pdshells` builds shells by calling `mkDevShell (variantAttrset // { name = ...; })`.
Any `shell` key in a variant attrset is therefore forwarded to `mkDevShell` and fully
honoured. The `machine.nix` test file demonstrates this correctly.

### Stage 5: no mk helper (unchanged from v2.1)

The `fn-defaultComposeStrategy` uses a local `phase` helper (binding `hookName` and
`fnField` together) which is scoped to the function and makes the parallel structure
visible without conflating the three distinct semantic roles of the parameters.

---

## 8. Error Taxonomy

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
