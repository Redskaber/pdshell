# pdshell — Changelog

---

## v2.1.0 — 2026-05-14

### Bug fixes

**mk-pdshell.nix**

1. **`inh_` → `in`** — the trailing underscore was non-idiomatic Nix and served
   no purpose. Restored to `in` as in the original v1.

2. **Stage 5: removed `mk` helper; restored explicit per-phase composition** —
   the `mk` helper conflated three semantically distinct roles under a single
   argument that happened to share the same string value in the default case
   (`hookName`, `customFieldKey`, and `fnFieldKey` were all `"preInputsHook"`
   for the first phase). Explicit per-phase blocks with `HookPhase.*` and
   `HookFnField.*` constants make every argument's role unambiguous.

3. **`_mkShellStripKeys` now includes `ShellKey.name`** — previously `name` was
   not stripped, so `baseParams` already contained `name` and the `// { name = ...; }`
   in `fn-build` silently shadowed it. Now `name` is stripped first and assigned
   exactly once. Also added `ShellKey._resolveStrategy` and `ShellKey._mergeStrategy`
   to prevent injected strategy functions from leaking into `pkgs.mkShell`.

4. **`HookPhase` and `HookFnField` constants used in pipeline stages** — both
   protocol attrsets were defined but never referenced inside the pipeline
   (bare string literals were used instead). All occurrences in `extractor`,
   `hookComposer`, and `pipeline.fn-compose` now reference the protocol constants.
   `HookFnField` added as a companion protocol to `HookPhase`.

**pdshells.nix**

5. **`fn-processDirectory` signature** — removed the spurious `ctx` parameter.
   The function immediately discarded it (rebuilding via `fn-initialContext`).
   Only `ctx.suffix` was used; replaced with an explicit `suffix: string` parameter.

6. **`fn-processMain` forwards `validPath`** — `validate.fn-assertFileExists`
   returns the validated path, but v2.0 piped its result and then passed the
   original `currentPath` to `fn-processDirectory`, rendering the assertion
   result useless. Fixed to pass `validPath`.

7. **`fn-processSubDirs` passes `ctx.suffix`** — with the signature change to
   `fn-processDirectory`, recursive calls now pass `ctx.suffix` explicitly.

8. **Global uniqueness is strictly evaluated** — replaced the `let` binding
   (lazy, could silently be skipped) with `assert lib.seq (...) true` so the
   uniqueness check is guaranteed to run before the shells are returned.

### New exports

- `HookFnField` — companion protocol to `HookPhase`; exported alongside `HookPhase`
  and `ContextPhase` for use by consumers and tests.

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
