# pdshell — Pipeline-Driven Nix Dev Shell Manager

> Version 2.2.0 · Nix · Pure functional · Zero side-effects

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Quick Start](#quick-start)
4. [File Layout](#file-layout)
5. [API Reference — mkDevShell](#api-reference--mkdevshell)
6. [Hook Lifecycle](#hook-lifecycle)
7. [Pipeline Stages](#pipeline-stages)
8. [State Machine](#state-machine)
9. [Protocol Definitions](#protocol-definitions)
10. [Strategy Pattern](#strategy-pattern)
11. [Plugin / combinFrom](#plugin--combinfrom)
12. [Directory Loader — pdshells](#directory-loader--pdshells)
13. [Naming Convention](#naming-convention)
14. [Extension Guide](#extension-guide)
15. [Configuration Reference](#configuration-reference)
16. [Troubleshooting](#troubleshooting)

---

## Overview

`pdshell` is a pure-Nix library for composing reproducible development shells.

| Module           | Purpose                                                                                               |
| ---------------- | ----------------------------------------------------------------------------------------------------- |
| `mk-pdshell.nix` | Low-level shell constructor — 7-stage typed pipeline → `pkgs.mkShell` derivation                      |
| `pdshells.nix`   | High-level directory loader — recursively discovers `.nix` files → flat `{ shellName = derivation; }` |

**Design goals**

| Principle              | Realisation                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------- |
| Dependency Inversion   | `_resolveStrategy`, `_mergeStrategy`, `_hookComposeStrategy`; `FileProcessStrategy`   |
| Pipeline Dataflow      | `\|>` operators throughout; every stage is `Context → Context`                        |
| Layered Architecture   | `mk-pdshell`: 7 explicit stages; `pdshells`: subdirs → common → default               |
| Incremental Mode       | Context accumulates fields per stage; never reset mid-pipeline                        |
| Strategy Management    | All three strategies first-class and swappable without touching core                  |
| State Machine          | `ContextPhase` / layer phase strings; `validate.fn-assertPhase` at each stage         |
| Lifecycle Management   | 5 named hook phases with guaranteed ordering and labelled sections                    |
| Boundary Clarity       | Public: `mkDevShell`, loader output; Internal: all other bindings                     |
| Data-Driven            | All behaviour parameterised; no hard-coded shell logic                                |
| Communication Protocol | `Context` is the typed message envelope; `LayerResult`/`FileResult` are typed outputs |
| Plugin / Hot-swap      | `combinFrom` = composable plugins; strategies injectable without touching core        |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                            PUBLIC API                                │
│   mkDevShell { ... }                pdshells { devDir; ... }         │
└──────────────────┬───────────────────────────┬───────────────────────┘
                   │                           │
    ┌──────────────▼───────────┐   ┌───────────▼────────────────────┐
    │    mk-pdshell.nix        │   │        pdshells.nix            │
    │    7-Stage Pipeline      │   │   Recursive Dir Loader         │
    │                          │◄──│   (delegates to mkDevShell)    │
    │  INIT                    │   │                                │
    │  RESOLVE ◄─resolveStrat  │   │  SCAN → SUBDIRS (depth-first)  │
    │  EXTRACT                 │   │       → COMMON  (non-default)  │
    │  MERGE   ◄─mergeStrat    │   │       → DEFAULT (default.nix)  │
    │  COMPOSE ◄─hookCompose   │   │       → DONE                   │
    │  BUILD                   │   │                                │
    │  EXEC    → pkgs.mkShell  │   └────────────────────────────────┘
    └──────────────────────────┘
```

---

## Quick Start

```nix
# flake.nix
{
  inputs.pdshell.url   = "github:redskaber/pdshell";
  inputs.nixpkgs.url   = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nix-types.url = "github:redskaber/nix-types";

  outputs = { self, nixpkgs, pdshell, ... }@inputs:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      inherit (pdshell.lib) mkDevShell pdshells;
    in {
      # Single shell via mkDevShell
      devShells.x86_64-linux.default = mkDevShell {
        inherit pkgs;
        buildInputs = [ pkgs.git pkgs.curl ];
        shellHook   = "echo hello";
      };

      # All shells from a directory tree via pdshells
      devShells.x86_64-linux = pdshells {
        inherit pkgs inputs;
        devDir = ./dev;
      };
    };
}
```

---

## File Layout

```
lib/dev/
├── mk-pdshell.nix       # Shell constructor
└── pdshells.nix         # Directory loader

dev/                     # Your shell definitions live here
├── default.nix          # → shell name: "default"
├── rust.nix             # → shell name: "rust"
└── backend/
    ├── default.nix      # → shell name: "backend"
    └── db.nix           # → shell name: "backend-db"
```

---

## API Reference — mkDevShell

```nix
mkDevShell {
  # ── Identity ────────────────────────────────────────────────────
  name                  ? "dev-shell",

  # ── Inputs ──────────────────────────────────────────────────────
  buildInputs           ? [],
  nativeBuildInputs     ? [],

  # ── Plugin composition ──────────────────────────────────────────
  combinFrom            ? [],        # list of shell-config attrsets to compose

  # ── Hook lifecycle (strings) ────────────────────────────────────
  preInputsHook         ? "",        # before buildInputs activated
  postInputsHook        ? "",        # after  buildInputs activated
  preShellHook          ? "",        # just before interactive shell
  postShellHook         ? "",        # at shell exit / cleanup
  shellHook             ? "",        # raw mkShell-compatible hook (legacy / inherited)

  # ── Hook lifecycle (functions) ──────────────────────────────────
  # Each *Fn receives { pkgs } and must return string | null.
  preInputsHookFn       ? null,
  postInputsHookFn      ? null,
  preShellHookFn        ? null,
  postShellHookFn       ? null,

  # ── Shell override ───────────────────────────────────────────────
  # exec'd AFTER all hooks; replaces the current process.
  # Must exist in PATH or be an absolute path.
  # Honoured at the variant level (pdshells passes variant attrsets to mkDevShell).
  shell                 ? null,

  # ── Extension points (dependency inversion) ──────────────────────
  _resolveStrategy      ? resolveStrategy.default,
  _mergeStrategy        ? mergeStrategy.unique,
  _hookComposeStrategy  ? hookComposer.fn-defaultComposeStrategy,

  # Any extra attrs are forwarded verbatim to pkgs.mkShell
  ...
}
```

---

## Hook Lifecycle

```
shell enter
    │
    ▼  preInputsHook / preInputsHookFn    ← PRE-INPUTS HOOK section
    │
    │  (buildInputs / nativeBuildInputs activated by Nix)
    │
    ▼  postInputsHook / postInputsHookFn  ← POST-INPUTS HOOK section
    │
    ▼  INHERITED SHELLHOOK                ← shellHook from combinFrom entries
    │                                        + top-level shellHook
    │
    ▼  preShellHook / preShellHookFn      ← PRE-SHELL HOOK section
    │
    ▼  postShellHook / postShellHookFn    ← POST-SHELL HOOK section
    │
    ▼  [if shell != null]  exec <shell>   ← FINAL SHELL OVERRIDE
```

Generated `shellHook` sections are labelled for grep-ability:

```bash
# === PRE-INPUTS HOOK ===
export CC=gcc

# === POST-INPUTS HOOK ===
export NODE_ENV=development

# === INHERITED SHELLHOOK ===
echo "from combinFrom"

# === PRE-SHELL HOOK ===
source .envrc

# === POST-SHELL HOOK ===
unset CC

# === FINAL SHELL OVERRIDE ===
exec zsh
```

Empty sections are omitted entirely.

---

## Pipeline Stages

| #   | FSM phase | Responsibility                                                    |
| --- | --------- | ----------------------------------------------------------------- |
| 1   | `INIT`    | Wrap raw args in a typed `Context`                                |
| 2   | `RESOLVE` | Unwrap `combinFrom` entries via the resolve strategy              |
| 3   | `EXTRACT` | Normalise hook structures using `HookPhase` constants             |
| 4   | `MERGE`   | Merge `buildInputs` / `nativeBuildInputs` via merge strategy      |
| 5   | `COMPOSE` | Build all hook lifecycle phases via the hook compose strategy     |
| 6   | `BUILD`   | Assemble final `pkgs.mkShell` parameter set; apply shell override |
| 7   | `EXEC`    | String validation + `pkgs.mkShell`                                |

Stage 5 is delegated to `_hookComposeStrategy` (default:
`hookComposer.fn-defaultComposeStrategy`), which composes each phase with
fully-named, role-distinct parameters (`HookPhase.*` and `HookFnField.*`).

---

## State Machine

### mk-pdshell Context

```
INIT ──▶ RESOLVE ──▶ EXTRACT ──▶ MERGE ──▶ COMPOSE ──▶ BUILD ──▶ EXEC
```

`validate.fn-assertPhase` is called at every stage entry.
Out-of-order execution → `PHASE VIOLATION` error.

### pdshells Layer (per directory)

```
SCAN ──▶ SUBDIRS ──▶ COMMON ──▶ DEFAULT ──▶ DONE
```

Each directory gets a **fresh** `LayerContext` — no state leaks between sibling directories.

---

## Protocol Definitions

All string constants are defined as typed attrsets.
No bare string literals appear inside the pipeline stages.

### HookPhase

```nix
HookPhase.PRE_INPUTS  = "preInputsHook"
HookPhase.POST_INPUTS = "postInputsHook"
HookPhase.PRE_SHELL   = "preShellHook"
HookPhase.POST_SHELL  = "postShellHook"
HookPhase.SHELL       = "shellHook"
```

### HookFnField (parallel to HookPhase)

```nix
HookFnField.PRE_INPUTS  = "preInputsHookFn"
HookFnField.POST_INPUTS = "postInputsHookFn"
HookFnField.PRE_SHELL   = "preShellHookFn"
HookFnField.POST_SHELL  = "postShellHookFn"
```

### ShellKey

Single source of truth for every field name in shell-config attrsets and `args`.
Covers `_resolveStrategy`, `_mergeStrategy`, and `_hookComposeStrategy` so all
extension overrides are stripped before forwarding to `pkgs.mkShell`.

---

## Strategy Pattern

### Resolve Strategy

Protocol: `entry:attrset → config:attrset`

| Name                      | Behaviour                                           |
| ------------------------- | --------------------------------------------------- |
| `resolveStrategy.default` | Unwrap `{ default = {...}; }` or use entry directly |

### Merge Strategy

Protocol: `base:[pkg] → extracted:[pkg] → merged:[pkg]`

| Name                     | Behaviour                                        |
| ------------------------ | ------------------------------------------------ |
| `mergeStrategy.unique`   | Concatenate + deduplicate (default)              |
| `mergeStrategy.prepend`  | `combinFrom` items first, then base; deduplicate |
| `mergeStrategy.baseOnly` | Ignore `combinFrom` inputs entirely              |

### Hook Compose Strategy

Protocol: `args → in:[hookAttrset] → resolvedCombin:[attrset] → composedPhases`

| Name                                     | Behaviour                                |
| ---------------------------------------- | ---------------------------------------- |
| `hookComposer.fn-defaultComposeStrategy` | Explicit per-phase composition (default) |

---

## Plugin / combinFrom

```nix
# base plugin (e.g. dev/base.nix)
{ pkgs, ... }:
{
  default = {
    buildInputs  = [ pkgs.git pkgs.curl ];
    preShellHook = ''export EDITOR=nvim'';
  };
}

# composite shell (e.g. dev/default.nix)
{ pkgs, dev, ... }:
{
  frontend = {
    combinFrom = [ dev.base ];          # dev = variantsTree from pdshells
    shellHook  = "echo 'frontend'";
  };
}
```

---

## Directory Loader — pdshells

### Processing order per directory

1. **Sub-directories** — depth-first recursive.
2. **Common `.nix` files** — each sees only the sub-directory `variantsTree`.
3. **`default.nix`** — sees sub-directory + common `variantsTrees`.

### Invocation

```nix
pdshells {
  inherit pkgs inputs;
  devDir  = ./dev;    # required
  shared  = {};       # optional — forwarded to every imported file
  suffix  = ".nix";  # optional — file extension filter (default: ".nix")
}
# → { shellName = <derivation>; ... }
```

### Global uniqueness

Shell names are checked for uniqueness globally at evaluation time.
Duplicate names cause a build-time `NAMING CONFLICT` error.
The check is strictly evaluated via `assert lib.seq` — it cannot be silently skipped.

---

## Naming Convention

| Source                    | Variant   | Result          |
| ------------------------- | --------- | --------------- |
| `dev/default.nix`         | `default` | `default`       |
| `dev/default.nix`         | `rust`    | `rust`          |
| `dev/backend/default.nix` | `default` | `backend`       |
| `dev/backend/default.nix` | `api`     | `backend-api`   |
| `dev/backend/db.nix`      | `default` | `backend-db`    |
| `dev/backend/db.nix`      | `pg`      | `backend-db-pg` |

---

## Extension Guide

Full details in [`docs/extension-guide.md`](docs/extension-guide.md).

### Swap the resolve strategy

```nix
mkDevShell {
  _resolveStrategy = entry:
    if builtins.hasAttr "cfg" entry then entry.cfg
    else resolveStrategy.default entry;
}
```

### Swap the merge strategy

```nix
mkDevShell {
  _mergeStrategy = mergeStrategy.prepend;   # combinFrom overrides base
}
```

### Swap the hook compose strategy

```nix
mkDevShell {
  _hookComposeStrategy = myCompose;   # myCompose : args → in → resolvedCombin → phases
}
```

### Dynamic hook function

```nix
mkDevShell {
  preShellHookFn = { pkgs }: ''
    export RUST_SRC_PATH="${pkgs.rustPlatform.rustLibSrc}"
  '';
}
```

### Shell override at the variant level

```nix
# dev/python/machine.nix
{ pkgs, ... }:
{
  default = {
    buildInputs = [ pkgs.python3 pkgs.zsh ];
    shell       = "zsh";   # exec'd after all hooks
  };
}
```

### Org-wide defaults wrapper

```nix
args: mkDevShell ({
  buildInputs    = [ pkgs.git pkgs.gnupg ];
  _mergeStrategy = mergeStrategy.prepend;
} // args);
```

### Access internals for testing

```nix
let
  subject = import ./lib/mk-pdshell.nix { inherit pkgs; };
in {
  test-resolve      = subject.resolveStrategy.default
    { default = { buildInputs = [ pkgs.git ]; }; };
  test-merge        = subject.mergeStrategy.unique [ pkgs.git ] [ pkgs.git pkgs.curl ];
  test-hookCompose  = subject.hookComposer.fn-defaultComposeStrategy
    { preInputsHook = "echo pre"; } [] [];
  test-shell        = subject.mkDevShell { buildInputs = [ pkgs.git ]; };
}
```

---

## Configuration Reference

### mkDevShell parameters

| Parameter              | Type               | Default                                  | Description                      |
| ---------------------- | ------------------ | ---------------------------------------- | -------------------------------- |
| `name`                 | string             | `"dev-shell"`                            | Derivation name prefix           |
| `buildInputs`          | `[pkg]`            | `[]`                                     | Runtime packages                 |
| `nativeBuildInputs`    | `[pkg]`            | `[]`                                     | Build-time packages              |
| `combinFrom`           | `[attrset]`        | `[]`                                     | Plugins to compose               |
| `preInputsHook`        | string             | `""`                                     | Hook before inputs               |
| `postInputsHook`       | string             | `""`                                     | Hook after inputs                |
| `preShellHook`         | string             | `""`                                     | Hook before shell                |
| `postShellHook`        | string             | `""`                                     | Hook after shell                 |
| `shellHook`            | string             | `""`                                     | Raw mkShell-compat / legacy hook |
| `*HookFn`              | `{pkgs}→str\|null` | `null`                                   | Dynamic hook functions           |
| `shell`                | string\|null       | `null`                                   | Final shell override             |
| `_resolveStrategy`     | function           | `resolveStrategy.default`                | combinFrom resolver              |
| `_mergeStrategy`       | function           | `mergeStrategy.unique`                   | Input merge algorithm            |
| `_hookComposeStrategy` | function           | `hookComposer.fn-defaultComposeStrategy` | Hook composition algorithm       |

### pdshells parameters

| Parameter | Type    | Required      | Description                                  |
| --------- | ------- | ------------- | -------------------------------------------- |
| `pkgs`    | nixpkgs | yes           | nixpkgs instance                             |
| `inputs`  | attrset | yes           | Flake inputs                                 |
| `devDir`  | path    | yes           | Root of shell definitions                    |
| `shared`  | attrset | no            | Forwarded to every imported file as `shared` |
| `suffix`  | string  | no (`".nix"`) | File extension filter                        |

---

## Troubleshooting

| Error                        | Cause                                       | Fix                                  |
| ---------------------------- | ------------------------------------------- | ------------------------------------ |
| `PHASE VIOLATION`            | Stage called out of order                   | Use pipeline in documented order     |
| `HOOK CONTRACT VIOLATION`    | `*HookFn` returned wrong type               | Return `string \| null` only         |
| `INVALID COMBIN ENTRY`       | No shell keys in combinFrom entry           | Add `buildInputs`, `shellHook`, etc. |
| `NAMING CONFLICT`            | Two shells resolve to the same name         | Rename variants or files             |
| `KEY COLLISION`              | `defaultAttrs` conflicts with existing tree | Rename variants in `default.nix`     |
| `STRUCTURAL AMBIGUITY`       | `foo.nix` and `foo/` coexist                | Keep only one source per base name   |
| `EMPTY DIRECTORY`            | No `.nix` files and no sub-dirs             | Add a shell or remove the directory  |
| `PATH NOT FOUND`             | `devDir` doesn't exist                      | Verify `devDir` path                 |
| Shell not found after `exec` | Binary not in `$PATH` at hook time          | Add shell package to `buildInputs`   |
