# @path: ~/projects/configs/nix-config/lib/dev/mk-pdshell.nix
# @author: redskaber
# @version: 2.1.0
# @datetime: 2026-05-14
# @description: lib::dev::mk-pdshell - Pipeline-driven shell constructor
#
# == ARCHITECTURE PRINCIPLES ==
# 1. Dependency Inversion   — all modules depend on abstractions (protocols/contracts), not concretions
# 2. Pipeline Dataflow      — |> explicit left-to-right transformation chain, zero hidden state
# 3. Layered Architecture   — validation → strategy → extraction → merge → compose → build → execute
# 4. Incremental Mode       — each pipeline stage produces an enriched Context (accumulator pattern)
# 5. Strategy Management    — hook, merge, resolve strategies are first-class, swappable
# 6. State Machine          — Context transitions through explicit phases (INIT→RESOLVE→EXTRACT→MERGE→COMPOSE→BUILD→EXEC)
# 7. Lifecycle Management   — preInputs → postInputs → inheritedShell → preShell → postShell hook lifecycle
# 8. Boundary Clarity       — public API surface (mkDevShell) vs internal modules (validate/strategy/pipeline)
# 9. Data-Driven            — all behaviour is parameterised; no hard-coded shell logic
# 10. Communication Protocol — Context is the typed message envelope passed between stages
# 11. Plugin / Hot-swap     — strategies and hooks are injectable; combinFrom entries are composable plugins


{ pkgs, ... }:
let
  lib = pkgs.lib;

  # ── PROTOCOL DEFINITIONS ──────────────────────────────────────────────────
  # Typed contracts: single shared language between all modules.
  # All string literals are centralised here — no bare strings elsewhere in the pipeline.

  ## Hook lifecycle phase field names (data-driven, not string-magic).
  ## These are the keys present on every normalised hook config attrset.
  HookPhase = {
    PRE_INPUTS  = "preInputsHook";
    POST_INPUTS = "postInputsHook";
    PRE_SHELL   = "preShellHook";
    POST_SHELL  = "postShellHook";
    SHELL       = "shellHook";     # legacy mkShell API surface
  };

  ## Corresponding *Fn field names (parallel structure to HookPhase).
  ## These are the keys for optional dynamic hook functions injected with { pkgs }.
  HookFnField = {
    PRE_INPUTS  = "preInputsHookFn";
    POST_INPUTS = "postInputsHookFn";
    PRE_SHELL   = "preShellHookFn";
    POST_SHELL  = "postShellHookFn";
  };

  ## Context FSM phase enum — enforced at every pipeline stage boundary.
  ContextPhase = {
    INIT    = "INIT";
    RESOLVE = "RESOLVE";
    EXTRACT = "EXTRACT";
    MERGE   = "MERGE";
    COMPOSE = "COMPOSE";
    BUILD   = "BUILD";
    EXEC    = "EXEC";
  };

  ## Known shell-config keys — single source of truth for all field names.
  ShellKey = {
    buildInputs        = "buildInputs";
    nativeBuildInputs  = "nativeBuildInputs";
    shellHook          = "shellHook";
    preInputsHook      = "preInputsHook";
    postInputsHook     = "postInputsHook";
    preShellHook       = "preShellHook";
    postShellHook      = "postShellHook";
    preInputsHookFn    = "preInputsHookFn";
    postInputsHookFn   = "postInputsHookFn";
    preShellHookFn     = "preShellHookFn";
    postShellHookFn    = "postShellHookFn";
    name               = "name";
    combinFrom         = "combinFrom";
    shell              = "shell";
    _resolveStrategy   = "_resolveStrategy";
    _mergeStrategy     = "_mergeStrategy";
  };

  ## Keys stripped from args before forwarding to pkgs.mkShell.
  ## ShellKey.name is stripped so fn-build assigns it exactly once.
  ## _resolveStrategy/_mergeStrategy are extension-point overrides, not shell params.
  _mkShellStripKeys = [
    ShellKey.name
    ShellKey.combinFrom
    ShellKey.preInputsHook   ShellKey.postInputsHook
    ShellKey.preShellHook    ShellKey.postShellHook
    ShellKey.shellHook
    ShellKey.preInputsHookFn ShellKey.postInputsHookFn
    ShellKey.preShellHookFn  ShellKey.postShellHookFn
    ShellKey.shell
    ShellKey._resolveStrategy
    ShellKey._mergeStrategy
  ];

  # ── VALIDATION MODULE ─────────────────────────────────────────────────────
  # All validators are curried for pipeline composition.
  # Convention: fn-assert* returns its last meaningful arg on success, throws on failure.

  validate = {
    ## Assert value is a list of attrsets (for combinFrom boundary check).
    fn-assertAttrsList = context: value:
      if lib.isList value && lib.all lib.isAttrs value
      then value
      else throw ''
        VALIDATION FAILED (${context}):
        • Expected : list of attrsets
        • Got      : ${builtins.typeOf value}
        Resolution : combinFrom must contain only valid config attrsets or language groups.
      '';

    ## Assert value is a string (for final shellHook boundary check).
    fn-assertString = context: value:
      if lib.isString value
      then value
      else throw ''
        VALIDATION FAILED (${context}):
        • Expected : string
        • Got      : ${builtins.typeOf value}
      '';

    ## Assert hook function result is string or null.
    fn-assertHookResult = hookName: result:
      if result == null   then ""
      else if lib.isString result then result
      else throw ''
        HOOK CONTRACT VIOLATION (${hookName}):
        • Expected : string or null
        • Got      : ${builtins.typeOf result}
        Resolution : Hook functions must return string or null.
                     Complex values require explicit serialization.
      '';

    ## FSM phase transition guard — ensures stages execute in declared order.
    fn-assertPhase = expectedPhase: ctx:
      if ctx.phase == expectedPhase
      then ctx
      else throw ''
        PHASE VIOLATION:
        • Expected phase : ${expectedPhase}
        • Current phase  : ${ctx.phase}
        Resolution       : Pipeline stages must execute in order.
      '';

    ## combinFrom entry must expose at least one shell-config key.
    fn-assertCombinEntry = entry:
      if builtins.hasAttr ShellKey.buildInputs       entry
      || builtins.hasAttr ShellKey.nativeBuildInputs entry
      || builtins.hasAttr ShellKey.shellHook         entry
      || builtins.hasAttr ShellKey.preInputsHook     entry
      || builtins.hasAttr ShellKey.postInputsHook    entry
      || builtins.hasAttr ShellKey.preShellHook      entry
      || builtins.hasAttr ShellKey.postShellHook     entry
      then entry
      else throw ''
        INVALID COMBIN ENTRY:
        • Missing all known shell-config keys.
        • Entry keys: ${builtins.concatStringsSep ", " (builtins.attrNames entry)}
        Resolution : combinFrom entries must contain at least one of:
          ${builtins.concatStringsSep ", " [
            ShellKey.buildInputs ShellKey.nativeBuildInputs ShellKey.shellHook
            ShellKey.preInputsHook ShellKey.postInputsHook
            ShellKey.preShellHook  ShellKey.postShellHook
          ]}
      '';
  };

  # ── RESOLVE STRATEGY MODULE ───────────────────────────────────────────────
  # Pluggable strategy for unwrapping combinFrom entries.
  # Protocol: entry:attrset → resolved-config:attrset

  resolveStrategy = {
    ## Default: unwrap { default = {...}; } wrapper or use entry directly.
    ## Mirrors original combinStrategy.fn-resolveEntry semantics.
    default = entry:
      if !lib.isAttrs entry
        then throw "combinFrom entry must be attrset, got: ${builtins.typeOf entry}"
      else if builtins.hasAttr "default" entry then entry.default
      else entry;

    ## Apply strategy then validate the resolved config.
    fn-resolve = strategy: entry:
      entry
      |> strategy
      |> validate.fn-assertCombinEntry;

    ## Process full combinFrom list: validate list type → map over entries.
    fn-processList = strategy: combinFrom:
      combinFrom
      |> (validate.fn-assertAttrsList "COMBINFROM INPUT")
      |> (list: map (resolveStrategy.fn-resolve strategy) list);
  };

  # ── EXTRACTOR MODULE ──────────────────────────────────────────────────────
  # Pure field extraction from resolved config lists. No side effects.

  extractor = {
    ## Extract and flatten a list-typed field across all resolved configs.
    fn-extractField = field: configs:
      configs
      |> (list: map (cfg: cfg.${field} or []) list)
      |> lib.concatLists;

    ## Normalise all hook structures into a uniform shape.
    ## Uses HookPhase protocol constants — no bare string literals.
    fn-extractHooks = configs:
      map (cfg: {
        ${HookPhase.SHELL}       = cfg.${HookPhase.SHELL}       or "";
        ${HookPhase.PRE_INPUTS}  = cfg.${HookPhase.PRE_INPUTS}  or "";
        ${HookPhase.POST_INPUTS} = cfg.${HookPhase.POST_INPUTS} or "";
        ${HookPhase.PRE_SHELL}   = cfg.${HookPhase.PRE_SHELL}   or "";
        ${HookPhase.POST_SHELL}  = cfg.${HookPhase.POST_SHELL}  or "";
      }) configs;
  };

  # ── MERGE STRATEGY MODULE ─────────────────────────────────────────────────
  # Pluggable merge strategies for buildInputs / nativeBuildInputs.
  # Protocol: base:[pkg] → extracted:[pkg] → merged:[pkg]

  mergeStrategy = {
    ## Default: concatenate then deduplicate (mirrors original merger.fn-mergeInputs).
    unique   = base: extracted: (base ++ extracted) |> lib.unique;

    ## combinFrom packages come first (they shadow / override base).
    prepend  = base: extracted: (extracted ++ base) |> lib.unique;

    ## Ignore combinFrom packages entirely — base list is authoritative.
    baseOnly = base: _extracted: base;

    ## Dispatcher — applies the chosen strategy.
    fn-mergeInputs = strategy: base: extracted:
      strategy base extracted;
  };

  # ── HOOK COMPOSER MODULE ──────────────────────────────────────────────────
  # Lifecycle-aware hook composition with labelled sections.
  # Uses HookPhase and HookFnField protocol constants throughout.

  hookComposer = {
    ## Execute an optional hook function injected with { pkgs }.
    ## null → ""; string → validated and returned; anything else → throw.
    fn-executeHookFn = hookName: fn:
      (fn == null)
      |> (isNull: if isNull then "" else fn { inherit pkgs; })
      |> (result: validate.fn-assertHookResult hookName result);


    ## Compose one lifecycle phase from three sources (in order):
    ##   1. inheritedList — hook strings from all resolved combinFrom entries
    ##   2. customStr     — top-level string hook for this phase (from args)
    ##   3. fn            — optional dynamic hook function (from args)
    ## hookName is used only for error reporting in fn-executeHookFn, not as a section label.
    fn-composePhase = hookName: fnFieldName: inheritedList: customStr: fn:
      inheritedList
      |> lib.concatStringsSep "\n"
      |> (inherited: inherited + "\n" + customStr
                   + "\n" + (hookComposer.fn-executeHookFn fnFieldName fn))
      |> lib.strings.trim;

    ## Wrap non-empty content in a labelled section header.
    ## Produces readable, grep-friendly shellHook output.
    fn-buildSection = label: content:
      if content == ""
      then ""
      else "# === ${label} ===\n${content}";

    ## Assemble all lifecycle sections into the final shellHook string.
    ## Empty sections are omitted. Sections separated by blank lines.
    fn-assemble = { inheritedShell, preInputs, postInputs, preShell, postShell }:
      [
        (hookComposer.fn-buildSection "INHERITED SHELLHOOK" inheritedShell)
        (hookComposer.fn-buildSection "PRE-INPUTS HOOK"     preInputs)
        (hookComposer.fn-buildSection "POST-INPUTS HOOK"    postInputs)
        (hookComposer.fn-buildSection "PRE-SHELL HOOK"      preShell)
        (hookComposer.fn-buildSection "POST-SHELL HOOK"     postShell)
      ]
      |> lib.filter (s: s != "")
      |> lib.concatStringsSep "\n\n";

    ## Append `exec <shell>` at the very end of the shellHook.
    ## exec replaces the current process so it must come after all other hooks.
    fn-applyShellOverride = shellOverride: hookStr:
      if shellOverride != null
      then hookStr + "\n\n# === FINAL SHELL OVERRIDE ===\nexec ${shellOverride}"
      else hookStr;
  };

  # ── CONTEXT (STATE MACHINE ENVELOPE) ─────────────────────────────────────
  # Context is the single typed message envelope flowing through every stage.
  # Each stage: Context → Context (pure accumulation, no mutation).
  #
  # FSM:  INIT → RESOLVE → EXTRACT → MERGE → COMPOSE → BUILD → EXEC
  #       (enforced at each stage entry by validate.fn-assertPhase)

  mkContext = args: {
    phase          = ContextPhase.INIT;   # current FSM state
    args           = args;                # caller args — immutable throughout the pipeline
    resolvedCombin = [];                  # RESOLVE  output: validated combinFrom configs
    extractedHooks = [];                  # EXTRACT  output: normalised hook structures
    mergedInputs   = {};                  # MERGE    output: { buildInputs, nativeBuildInputs }
    composedHooks  = {};                  # COMPOSE  output: { inheritedShell, preInputs, postInputs, preShell, postShell }
    mkShellParams  = {};                  # BUILD    output: final pkgs.mkShell parameter set
  };

  # ── PIPELINE STAGES ───────────────────────────────────────────────────────
  # Each stage: Context → Context  (pure function, no side effects).
  # Assembled and invoked in mkDevShell (the public entry point).

  pipeline = {

    # Stage 1 – INIT
    # mkContext already sets phase=INIT.  This explicit stage makes the pipeline
    # chain self-documenting and allows future pre-init hooks to be inserted cleanly.
    fn-init = ctx:
      ctx // { phase = ContextPhase.INIT; };

    # Stage 2 – RESOLVE
    # Unwrap and validate every combinFrom entry via the injected resolve strategy.
    fn-resolve = resolveStrat: ctx:
      validate.fn-assertPhase ContextPhase.INIT ctx
      |> (ctx:
        ctx.args.combinFrom or []
        |> (resolveStrategy.fn-processList resolveStrat)
        |> (resolved: ctx // {
          phase          = ContextPhase.RESOLVE;
          resolvedCombin = resolved;
        })
      );

    # Stage 3 – EXTRACT
    # Normalise hook structures from all resolved configs using HookPhase constants.
    fn-extract = ctx:
      validate.fn-assertPhase ContextPhase.RESOLVE ctx
      |> (ctx:
        ctx.resolvedCombin
        |> extractor.fn-extractHooks
        |> (hooks: ctx // {
          phase          = ContextPhase.EXTRACT;
          extractedHooks = hooks;
        })
      );

    # Stage 4 – MERGE
    # Deterministically merge buildInputs and nativeBuildInputs.
    fn-merge = mergeStrat: ctx:
      validate.fn-assertPhase ContextPhase.EXTRACT ctx
      |> (ctx:
        let
          buildInputs = mergeStrategy.fn-mergeInputs mergeStrat
            (ctx.args.buildInputs or [])
            (extractor.fn-extractField ShellKey.buildInputs ctx.resolvedCombin);
          nativeBuildInputs = mergeStrategy.fn-mergeInputs mergeStrat
            (ctx.args.nativeBuildInputs or [])
            (extractor.fn-extractField ShellKey.nativeBuildInputs ctx.resolvedCombin);
        in ctx // {
          phase        = ContextPhase.MERGE;
          mergedInputs = { inherit buildInputs nativeBuildInputs; };
        }
      );

    # Stage 5 – COMPOSE
    # Build each hook lifecycle phase explicitly.
    #
    # Design rationale: each phase is composed with fully named, role-distinct parameters.
    # No mk helper — mk would conflate hookName, fieldKey, and customField which happen
    # to share the same string value in the default case but carry different semantic roles:
    #   hookName     — HookPhase.*   — section label and inherited-list key
    #   fnFieldName  — HookFnField.* — key for the optional dynamic Fn in args
    #   customStr    — args.${HookPhase.*}  — top-level string hook from caller
    #   fn           — args.${HookFnField.*} — optional dynamic hook function
    fn-compose = ctx:
      validate.fn-assertPhase ContextPhase.MERGE ctx
      |> (ctx:
        let
          inh  = ctx.extractedHooks;   # normalised hook list from EXTRACT stage
          args = ctx.args;

          preInputs = hookComposer.fn-composePhase
            HookPhase.PRE_INPUTS
            HookFnField.PRE_INPUTS
            (map (h: h.${HookPhase.PRE_INPUTS}) inh)
            (args.${HookPhase.PRE_INPUTS}  or "")
            (args.${HookFnField.PRE_INPUTS} or null);

          postInputs = hookComposer.fn-composePhase
            HookPhase.POST_INPUTS
            HookFnField.POST_INPUTS
            (map (h: h.${HookPhase.POST_INPUTS}) inh)
            (args.${HookPhase.POST_INPUTS}  or "")
            (args.${HookFnField.POST_INPUTS} or null);

          preShell = hookComposer.fn-composePhase
            HookPhase.PRE_SHELL
            HookFnField.PRE_SHELL
            (map (h: h.${HookPhase.PRE_SHELL}) inh)
            (args.${HookPhase.PRE_SHELL}  or "")
            (args.${HookFnField.PRE_SHELL} or null);

          postShell = hookComposer.fn-composePhase
            HookPhase.POST_SHELL
            HookFnField.POST_SHELL
            (map (h: h.${HookPhase.POST_SHELL}) inh)
            (args.${HookPhase.POST_SHELL}  or "")
            (args.${HookFnField.POST_SHELL} or null);

          # inheritedShell: aggregates legacy shellHook values from all combinFrom entries
          # plus the top-level shellHook (mkShell API compatibility layer).
          # Parentheses are required: |> binds looser than = in let bindings.
          inheritedShell =
            (extractor.fn-extractField HookPhase.SHELL ctx.resolvedCombin
            |> lib.concatStringsSep "\n"
            |> (s: s + "\n" + (args.${HookPhase.SHELL} or ""))
            |> lib.strings.trim);

        in ctx // {
          phase         = ContextPhase.COMPOSE;
          composedHooks = { inherit preInputs postInputs preShell postShell inheritedShell; };
        }
      );

    # Stage 6 – BUILD
    # Assemble the final pkgs.mkShell parameter set.
    # ShellKey.name is in _mkShellStripKeys so baseParams never contains it;
    # it is assigned exactly once in the // merge below.
    fn-build = ctx:
      validate.fn-assertPhase ContextPhase.COMPOSE ctx
      |> (ctx:
        let
          baseHook = hookComposer.fn-assemble {
            inherit (ctx.composedHooks)
              inheritedShell preInputs postInputs preShell postShell;
          };
          shellHook  = hookComposer.fn-applyShellOverride
            (ctx.args.shell or null)
            baseHook;
          baseParams = builtins.removeAttrs ctx.args _mkShellStripKeys;
        in ctx // {
          phase         = ContextPhase.BUILD;
          mkShellParams = baseParams // {
            name              = ctx.args.name or "dev-shell";
            buildInputs       = ctx.mergedInputs.buildInputs;
            nativeBuildInputs = ctx.mergedInputs.nativeBuildInputs;
            inherit shellHook;
          };
        }
      );

    # Stage 7 – EXEC
    # Final type validation then delegate to pkgs.mkShell.
    fn-exec = ctx:
      validate.fn-assertPhase ContextPhase.BUILD ctx
      |> (ctx:
        validate.fn-assertString "FINAL SHELLHOOK" ctx.mkShellParams.shellHook
        |> (_: ctx // { phase = ContextPhase.EXEC; })
        |> (ctx: pkgs.mkShell ctx.mkShellParams)
      );
  };

  # ── PUBLIC API ────────────────────────────────────────────────────────────
  # Single entry point. All parameters are optional; sane defaults apply.
  #
  # EXTENSION POINTS (dependency inversion)
  # ────────────────────────────────────────
  # _resolveStrategy  — combinFrom-entry unwrapping logic
  #                     default : resolveStrategy.default
  #                     protocol: entry:attrset → config:attrset
  #
  # _mergeStrategy    — input-list merge algorithm
  #                     default : mergeStrategy.unique
  #                     protocol: base:[pkg] → extracted:[pkg] → merged:[pkg]
  #
  # HOOK LIFECYCLE ORDER
  # ────────────────────
  # preInputsHook  / preInputsHookFn  → before buildInputs activated
  # postInputsHook / postInputsHookFn → after  buildInputs activated
  # [inherited shellHook values from combinFrom + top-level shellHook]
  # preShellHook   / preShellHookFn   → just before interactive shell
  # postShellHook  / postShellHookFn  → at shell exit / cleanup
  # shell                             → exec'd last, replaces current process
  #
  # SHELL OVERRIDE
  # ──────────────
  # shell = "zsh";   exec'd AFTER all hooks; replaces the current process.
  #                  Must exist in PATH or be an absolute path.
  #                  Only honoured at the top level — combinFrom entries are ignored.

  mkDevShell = {
    name               ? "dev-shell",
    buildInputs        ? [],
    nativeBuildInputs  ? [],
    combinFrom         ? [],
    preInputsHook      ? "",
    postInputsHook     ? "",
    preShellHook       ? "",
    postShellHook      ? "",
    shellHook          ? "",
    preInputsHookFn    ? null,
    postInputsHookFn   ? null,
    preShellHookFn     ? null,
    postShellHookFn    ? null,
    shell              ? null,
    _resolveStrategy   ? resolveStrategy.default,
    _mergeStrategy     ? mergeStrategy.unique,
    ...
  } @ args:
    # FULL DATAFLOW PIPELINE — explicit, traceable, maintainable
    args
    |> mkContext
    |> pipeline.fn-init
    |> (pipeline.fn-resolve _resolveStrategy)
    |> pipeline.fn-extract
    |> (pipeline.fn-merge   _mergeStrategy)
    |> pipeline.fn-compose
    |> pipeline.fn-build
    |> pipeline.fn-exec;

in {
  # Public API
  inherit mkDevShell;

  # Exported internals — for testing, extension, and pdshells.nix integration
  inherit validate resolveStrategy extractor mergeStrategy hookComposer pipeline;
  inherit HookPhase HookFnField ContextPhase ShellKey;
}
