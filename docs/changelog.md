# pdshell — Changelog

---

## v2.2.0 — 2026-05-14

### Bug fixes

**mk-pdshell.nix**

1. **`fn-assemble` lifecycle order corrected** — v2.1 rendered sections in the
   order `INHERITED SHELLHOOK → PRE-INPUTS → POST-INPUTS → PRE-SHELL → POST-SHELL`,
   which contradicted the documented lifecycle
   (`preInputs → postInputs → inheritedShell → preShell → postShell`).
   v2.2 restores the correct assembly order.

2. **`fn-composePhase` first parameter clarified** — The parameter was named
   `hookName` but was only forwarded to `fn-executeHookFn` (whose error-reporting
   parameter was renamed `fnFieldName`). The parameter is now named `hookName`
   with a clear comment explaining it is reserved for section-label use
   (section labelling occurs in `fn-assemble`, not `fn-composePhase`). The
   composition logic now correctly passes `fnFieldName` to `fn-executeHookFn`.

3. **`fn-getAttrsFiles` suffix threading** — `fs.fn-getAttrsFiles` now accepts
   `currentSuffix` explicitly instead of silently using `fs.default-nixSuffix`,
   so the module-level `suffix` parameter propagates correctly through all
   `FileProcessStrategy` file list lookups.

4. **`shell` override documented as variant-level** — The comment and docs
   previously implied `shell` was only honoured at the "top level" of
   `mkDevShell`. Because `pdshells` calls `mkDevShell (variantAttrset // { name
= ...; })`, the `shell` key in any variant config **is** forwarded and
   honoured. Docs and test files corrected accordingly.

### New features

**mk-pdshell.nix**

5. **`_hookComposeStrategy` extension point** — A third injectable strategy has
   been added. The default implementation (`hookComposer.fn-defaultComposeStrategy`)
   reproduces the v2.1 per-phase explicit composition, but callers can now
   replace the entire hook-composition algorithm without modifying core.
   Protocol: `args → in:[hookAttrset] → resolvedCombin:[attrset] → composedPhases`.
   `ShellKey._hookComposeStrategy` added; the key is stripped before `pkgs.mkShell`.

6. **`hookComposer.fn-defaultComposeStrategy` extracted** — The per-phase
   composition logic previously inlined in `pipeline.fn-compose` is now a
   named, testable function in `hookComposer`. This enables unit testing of
   hook composition without running the full pipeline.

**pdshells.nix**

7. **`FileProcessStrategy.fn-getFileList` signature extended** — Now
   `currentPath → currentSuffix → [fileName]` (was `currentPath → [fileName]`).
   Both `CommonStrategy` and `DefaultStrategy` updated. Callers of
   `fn-execute` pass `ctx.suffix` through the strategy.

### Documentation

8. **Test files rewritten** — All `test/dev/**/*.nix` files now have accurate
   per-file headers, meaningful `buildInputs`, and demonstrate different features
   (lifecycle hooks, shell override, combinFrom, etc.).

9. **`flake.nix` added** — Full top-level flake with `lib`, `devShells`, and
   basic `checks` output.

---

## v2.1.0 — 2026-05-14

### Bug fixes

**mk-pdshell.nix**

1. **`inh_` → `in`** — trailing underscore was non-idiomatic Nix. Restored.

2. **Stage 5: removed `mk` helper; restored explicit per-phase composition** —
   the helper conflated `hookName`, `customFieldKey`, and `fnFieldKey` which
   happened to share the same string value in the default case.

3. **`_mkShellStripKeys` now includes `ShellKey.name`** — prevents silent
   duplicate-key shadowing; `name` is now assigned exactly once.
   Added `ShellKey._resolveStrategy` and `ShellKey._mergeStrategy`.

4. **`HookPhase` and `HookFnField` constants used throughout pipeline** — bare
   string literals replaced. `HookFnField` added as a companion protocol.

**pdshells.nix**

5. **`fn-processDirectory` signature** — removed spurious `ctx` parameter;
   replaced with explicit `suffix` string.

6. **`fn-processMain` forwards `validPath`** — validation result was previously
   discarded.

7. **`fn-processSubDirs` passes `ctx.suffix`** — consistent with signature change.

8. **Global uniqueness strictly evaluated** — `let` binding replaced with
   `assert lib.seq (...) true`.

### New exports

- `HookFnField` — exported alongside `HookPhase` and `ContextPhase`.

---

## v2.0.0 — 2026-05-14

### Breaking changes

- `combinFrom` entries with no recognised shell-config keys now throw
  `INVALID COMBIN ENTRY` instead of being silently ignored.
- `pdshells`: layer context re-initialised per directory (prevents state leakage).

### New features

- **State machine** — `Context.phase` enforced at every pipeline stage.
- **Dependency inversion** — `_resolveStrategy` and `_mergeStrategy` injection points.
- **Additional merge strategies** — `mergeStrategy.prepend` and `mergeStrategy.baseOnly`.
- **Protocol definitions** — `HookPhase`, `ContextPhase`, `ShellKey` attrsets.
- **Exported internals** — all modules exported for testing and extension.
- **Layer state machine** — `LayerContext.phase` transitions.
- **Structural validation** — file/directory name collision detection.

---

## v1.0.0 — 2026-03-01

Initial release.

- `mk-pdshell.nix`: 7-stage pipeline constructor.
- `pdshells.nix`: recursive directory loader with depth-first traversal.
- `combinFrom` plugin composition mechanism.
- 5-phase hook lifecycle.
- `shell` override via `exec`.
