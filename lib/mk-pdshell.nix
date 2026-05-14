# @path: ~/projects/configs/nix-config/lib/dev/mk-pdshell.nix
# @author: redskaber
# @version: 2.2.0
# @datetime: 2026-05-14
# @description: lib::dev::mk-pdshell — Pipeline-driven Nix dev shell constructor
#
# == ARCHITECTURE PRINCIPLES ==
#  1. Dependency Inversion   — all modules depend on protocol contracts, not concretions
#  2. Pipeline Dataflow      — |> explicit left-to-right transformation chain, zero hidden state
#  3. Layered Architecture   — validate → protocol → strategy → extract → merge → compose → build → exec
#  4. Incremental Mode       — each stage enriches Context; never reset mid-pipeline
#  5. Strategy Management    — resolve, merge, hookCompose strategies are first-class and swappable
#  6. State Machine          — Context.phase transitions INIT→RESOLVE→EXTRACT→MERGE→COMPOSE→BUILD→EXEC
#  7. Lifecycle Management   — preInputs → postInputs → inheritedShell → preShell → postShell
#  8. Boundary Clarity       — public: mkDevShell; internal: validate/strategy/pipeline/*
#  9. Data-Driven            — all behaviour parameterised via protocol constants; no bare strings
# 10. Communication Protocol — Context is the single typed envelope flowing between stages
# 11. Plugin / Hot-swap      — combinFrom = composable plugins; all strategies injectable

{ pkgs, ... }:
let
  lib = pkgs.lib;

  # ════════════════════════════════════════════════════════════════════════════
  # §1  PROTOCOL DEFINITIONS
  #     Single source of truth for every string constant used in the pipeline.
  #     No bare string literals may appear in pipeline stages — use these constants.
  # ════════════════════════════════════════════════════════════════════════════

  ## Hook lifecycle phase field names.
  ## Keys present on every normalised hook-config attrset produced by the extractor.
  HookPhase = {
    PRE_INPUTS  = "preInputsHook";   # executed before buildInputs are activated
    POST_INPUTS = "postInputsHook";  # executed after  buildInputs are activated
    PRE_SHELL   = "preShellHook";    # executed just before the interactive shell
    POST_SHELL  = "postShellHook";   # executed at shell exit / cleanup
    SHELL       = "shellHook";       # legacy mkShell-compatible hook (API compatibility)
  };

  ## Parallel Fn-field names — keys for optional dynamic hook functions (receive { pkgs }).
  ## Parallel structure to HookPhase: PRE_INPUTS → "preInputsHookFn", etc.
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

  ## All known shell-config field names — single source of truth.
  ## Also covers extension-point keys so they are stripped before pkgs.mkShell.
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
    _hookComposeStrategy = "_hookComposeStrategy";
  };

  ## Keys stripped from args before forwarding to pkgs.mkShell.
  ##   ShellKey.name            — stripped so fn-build assigns it exactly once
  ##   ShellKey._*Strategy      — extension overrides; not valid pkgs.mkShell params
  ##   Hook string/fn fields    — consumed by the pipeline; must not reach mkShell
  _mkShellStripKeys = [
    ShellKey.name
    ShellKey.combinFrom
    ShellKey.preInputsHook    ShellKey.postInputsHook
    ShellKey.preShellHook     ShellKey.postShellHook
    ShellKey.shellHook
    ShellKey.preInputsHookFn  ShellKey.postInputsHookFn
    ShellKey.preShellHookFn   ShellKey.postShellHookFn
    ShellKey.shell
    ShellKey._resolveStrategy
    ShellKey._mergeStrategy
    ShellKey._hookComposeStrategy
  ];

  # ════════════════════════════════════════════════════════════════════════════
  # §2  VALIDATION MODULE
  #     All validators are curried for pipeline composition.
  #     Convention: fn-assert* returns its principal arg on success, throws on failure.
  # ════════════════════════════════════════════════════════════════════════════

  validate = {

    ## Assert value is a list of attrsets (combinFrom boundary check).
    fn-assertAttrsList = context: value:
      if lib.isList value && lib.all lib.isAttrs value
      then value
      else throw ''
        VALIDATION FAILED (${context}):
        • Expected : list of attrsets
        • Got      : ${builtins.typeOf value}
        Resolution : combinFrom must contain only valid config attrsets.
      '';

    ## Assert value is a string (final shellHook boundary check).
    fn-assertString = context: value:
      if lib.isString value
      then value
      else throw ''
        VALIDATION FAILED (${context}):
        • Expected : string
        • Got      : ${builtins.typeOf value}
      '';

    ## Assert hook function result is string or null.
    fn-assertHookResult = fnFieldName: result:
      if result == null        then ""
      else if lib.isString result then result
      else throw ''
        HOOK CONTRACT VIOLATION (${fnFieldName}):
        • Expected : string or null
        • Got      : ${builtins.typeOf result}
        Resolution : Hook functions must return string or null.
                     Serialize complex values before returning.
      '';

    ## FSM phase transition guard — ensures stages execute in declared order.
    fn-assertPhase = expectedPhase: ctx:
      if ctx.phase == expectedPhase
      then ctx
      else throw ''
        PHASE VIOLATION:
        • Expected phase : ${expectedPhase}
        • Current phase  : ${ctx.phase}
        Resolution       : Pipeline stages must execute in the documented order.
      '';

    ## combinFrom entry must expose at least one recognised shell-config key.
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
        • No recognised shell-config key found.
        • Entry keys: ${builtins.concatStringsSep ", " (builtins.attrNames entry)}
        Resolution : combinFrom entries must contain at least one of:
          ${builtins.concatStringsSep ", " [
            ShellKey.buildInputs ShellKey.nativeBuildInputs ShellKey.shellHook
            ShellKey.preInputsHook ShellKey.postInputsHook
            ShellKey.preShellHook  ShellKey.postShellHook
          ]}
      '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §3  RESOLVE STRATEGY MODULE
  #     Pluggable strategy for unwrapping combinFrom entries.
  #     Protocol: entry:attrset → resolved-config:attrset
  # ════════════════════════════════════════════════════════════════════════════

  resolveStrategy = {

    ## Default: unwrap { default = {...}; } wrapper, or use entry directly.
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

    ## Validate list type, then map strategy over every entry.
    fn-processList = strategy: combinFrom:
      combinFrom
      |> (validate.fn-assertAttrsList "COMBINFROM INPUT")
      |> (list: map (resolveStrategy.fn-resolve strategy) list);
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §4  EXTRACTOR MODULE
  #     Pure field extraction from resolved config lists. No side effects.
  # ════════════════════════════════════════════════════════════════════════════

  extractor = {

    ## Extract and flatten a list-typed field across all resolved configs.
    fn-extractField = field: configs:
      configs
      |> (list: map (cfg: cfg.${field} or []) list)
      |> lib.concatLists;

    ## Normalise hook structures into a uniform shape using HookPhase constants.
    ## Every output attrset contains exactly the five HookPhase keys.
    fn-extractHooks = configs:
      map (cfg: {
        ${HookPhase.SHELL}       = cfg.${HookPhase.SHELL}       or "";
        ${HookPhase.PRE_INPUTS}  = cfg.${HookPhase.PRE_INPUTS}  or "";
        ${HookPhase.POST_INPUTS} = cfg.${HookPhase.POST_INPUTS} or "";
        ${HookPhase.PRE_SHELL}   = cfg.${HookPhase.PRE_SHELL}   or "";
        ${HookPhase.POST_SHELL}  = cfg.${HookPhase.POST_SHELL}  or "";
      }) configs;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §5  MERGE STRATEGY MODULE
  #     Pluggable strategies for merging buildInputs / nativeBuildInputs.
  #     Protocol: base:[pkg] → extracted:[pkg] → merged:[pkg]
  # ════════════════════════════════════════════════════════════════════════════

  mergeStrategy = {

    ## Default: concatenate then deduplicate.
    unique   = base: extracted: (base ++ extracted) |> lib.unique;

    ## combinFrom packages come first (they shadow / override base).
    prepend  = base: extracted: (extracted ++ base) |> lib.unique;

    ## Ignore combinFrom packages — base list is authoritative.
    baseOnly = base: _extracted: base;

    ## Dispatcher — applies the chosen strategy to (base, extracted).
    fn-mergeInputs = strategy: base: extracted:
      strategy base extracted;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §6  HOOK COMPOSER MODULE
  #     Lifecycle-aware hook composition with labelled, grep-friendly sections.
  #
  #     LIFECYCLE ORDER (matches documented order):
  #       PRE-INPUTS HOOK
  #       POST-INPUTS HOOK
  #       INHERITED SHELLHOOK   ← combinFrom shellHooks + top-level shellHook
  #       PRE-SHELL HOOK
  #       POST-SHELL HOOK
  #       [FINAL SHELL OVERRIDE]
  # ════════════════════════════════════════════════════════════════════════════

  hookComposer = {

    ## Execute an optional dynamic hook function receiving { pkgs }.
    ## null → ""; string result → validated and returned; anything else → throw.
    fn-executeHookFn = fnFieldName: fn:
      (fn == null)
      |> (isNull: if isNull then "" else fn { inherit pkgs; })
      |> (result: validate.fn-assertHookResult fnFieldName result);

    ## Compose one lifecycle phase from three ordered sources:
    ##   1. inheritedList — hook strings from resolved combinFrom entries for this phase
    ##   2. customStr     — caller's top-level string hook for this phase
    ##   3. fn            — caller's optional dynamic Fn (receives { pkgs })
    ##
    ## fnFieldName is used as the error label in fn-executeHookFn (and for future
    ## diagnostics); hookName is reserved for section-label use in fn-assemble.
    fn-composePhase = hookName: fnFieldName: inheritedList: customStr: fn:
      inheritedList
      |> lib.concatStringsSep "\n"
      |> (inherited: inherited + "\n" + customStr
                   + "\n" + (hookComposer.fn-executeHookFn fnFieldName fn))
      |> lib.strings.trim;

    ## Default hookCompose strategy: wraps fn-composePhase for all four phases.
    ## Protocol: args → extractedHooks → composedPhases attrset
    ##   composedPhases = { preInputs, postInputs, preShell, postShell, inheritedShell }
    fn-defaultComposeStrategy = args: inh: resolvedCombin:
      let
        phase = hookName: fnField:
          hookComposer.fn-composePhase
            hookName
            fnField
            (map (h: h.${hookName}) inh)
            (args.${hookName}  or "")
            (args.${fnField}   or null);
      in {
        preInputs  = phase HookPhase.PRE_INPUTS  HookFnField.PRE_INPUTS;
        postInputs = phase HookPhase.POST_INPUTS HookFnField.POST_INPUTS;
        preShell   = phase HookPhase.PRE_SHELL   HookFnField.PRE_SHELL;
        postShell  = phase HookPhase.POST_SHELL  HookFnField.POST_SHELL;
        inheritedShell =
          (extractor.fn-extractField HookPhase.SHELL resolvedCombin
          |> lib.concatStringsSep "\n"
          |> (s: s + "\n" + (args.${HookPhase.SHELL} or ""))
          |> lib.strings.trim);
      };

    ## Wrap non-empty content in a labelled section header.
    fn-buildSection = label: content:
      if content == ""
      then ""
      else "# === ${label} ===\n${content}";

    ## Assemble all lifecycle sections in the documented lifecycle order:
    ##   PRE-INPUTS → POST-INPUTS → INHERITED SHELLHOOK → PRE-SHELL → POST-SHELL
    ## Empty sections are omitted; non-empty sections separated by blank lines.
    fn-assemble = { preInputs, postInputs, inheritedShell, preShell, postShell }:
      [
        (hookComposer.fn-buildSection "PRE-INPUTS HOOK"      preInputs)
        (hookComposer.fn-buildSection "POST-INPUTS HOOK"     postInputs)
        (hookComposer.fn-buildSection "INHERITED SHELLHOOK"  inheritedShell)
        (hookComposer.fn-buildSection "PRE-SHELL HOOK"       preShell)
        (hookComposer.fn-buildSection "POST-SHELL HOOK"      postShell)
      ]
      |> lib.filter (s: s != "")
      |> lib.concatStringsSep "\n\n";

    ## Append `exec <shell>` at the very end of the assembled shellHook.
    ## exec replaces the current process — must come after all other hooks.
    fn-applyShellOverride = shellOverride: hookStr:
      if shellOverride != null
      then hookStr + "\n\n# === FINAL SHELL OVERRIDE ===\nexec ${shellOverride}"
      else hookStr;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §7  CONTEXT  (STATE MACHINE ENVELOPE)
  #     The single typed message envelope flowing through every pipeline stage.
  #     Each stage: Context → Context  (pure accumulation, no mutation).
  #
  #     FSM:  INIT → RESOLVE → EXTRACT → MERGE → COMPOSE → BUILD → EXEC
  #           (guarded at each stage entry by validate.fn-assertPhase)
  # ════════════════════════════════════════════════════════════════════════════

  mkContext = args: {
    phase          = ContextPhase.INIT;   # current FSM state
    args           = args;                # caller args — immutable across the entire pipeline
    resolvedCombin = [];                  # RESOLVE  → validated combinFrom configs
    extractedHooks = [];                  # EXTRACT  → normalised hook structures
    mergedInputs   = {};                  # MERGE    → { buildInputs, nativeBuildInputs }
    composedHooks  = {};                  # COMPOSE  → { preInputs, postInputs, inheritedShell, preShell, postShell }
    mkShellParams  = {};                  # BUILD    → final pkgs.mkShell parameter set
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §8  PIPELINE STAGES
  #     Each stage: Context → Context  (pure, no side effects).
  #     Assembled and invoked inside mkDevShell (the public entry point).
  # ════════════════════════════════════════════════════════════════════════════

  pipeline = {

    # ── Stage 1: INIT ────────────────────────────────────────────────────────
    # Idempotent — mkContext already sets phase=INIT.
    # Explicit stage makes the pipeline chain self-documenting and
    # allows future pre-init interceptors to be inserted cleanly.
    fn-init = ctx:
      ctx // { phase = ContextPhase.INIT; };

    # ── Stage 2: RESOLVE ─────────────────────────────────────────────────────
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

    # ── Stage 3: EXTRACT ─────────────────────────────────────────────────────
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

    # ── Stage 4: MERGE ───────────────────────────────────────────────────────
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

    # ── Stage 5: COMPOSE ─────────────────────────────────────────────────────
    # Build each hook lifecycle phase.
    #
    # Delegated to the _hookComposeStrategy (injectable via args, defaulting to
    # hookComposer.fn-defaultComposeStrategy).  The strategy receives:
    #   args           — full caller args (for top-level hook strings and Fns)
    #   inh            — normalised list from EXTRACT stage
    #   resolvedCombin — for SHELL / inheritedShell aggregation
    #
    # Design note: explicit per-phase composition (inside fn-defaultComposeStrategy)
    # avoids conflating hookName, fnFieldName, and customStr which share the same
    # string value in the default case but carry distinct semantic roles.
    fn-compose = hookComposeStrat: ctx:
      validate.fn-assertPhase ContextPhase.MERGE ctx
      |> (ctx:
        hookComposeStrat ctx.args ctx.extractedHooks ctx.resolvedCombin
        |> (composed: ctx // {
          phase         = ContextPhase.COMPOSE;
          composedHooks = composed;
        })
      );

    # ── Stage 6: BUILD ───────────────────────────────────────────────────────
    # Assemble the final pkgs.mkShell parameter set.
    # ShellKey.name is in _mkShellStripKeys → baseParams never contains it;
    # assigned exactly once in the // merge below.
    fn-build = ctx:
      validate.fn-assertPhase ContextPhase.COMPOSE ctx
      |> (ctx:
        let
          baseHook = hookComposer.fn-assemble {
            inherit (ctx.composedHooks)
              preInputs postInputs inheritedShell preShell postShell;
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

    # ── Stage 7: EXEC ────────────────────────────────────────────────────────
    # Final type validation then delegate to pkgs.mkShell.
    fn-exec = ctx:
      validate.fn-assertPhase ContextPhase.BUILD ctx
      |> (ctx:
        validate.fn-assertString "FINAL SHELLHOOK" ctx.mkShellParams.shellHook
        |> (_: ctx // { phase = ContextPhase.EXEC; })
        |> (ctx: pkgs.mkShell ctx.mkShellParams)
      );
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §9  PUBLIC API — mkDevShell
  #
  #     All parameters are optional; sane defaults are provided.
  #
  #     EXTENSION POINTS (dependency inversion)
  #     ────────────────────────────────────────
  #     _resolveStrategy      — combinFrom entry unwrapping
  #                             default : resolveStrategy.default
  #                             protocol: entry:attrset → config:attrset
  #
  #     _mergeStrategy        — input list merge algorithm
  #                             default : mergeStrategy.unique
  #                             protocol: base:[pkg] → extracted:[pkg] → merged:[pkg]
  #
  #     _hookComposeStrategy  — hook composition for all lifecycle phases
  #                             default : hookComposer.fn-defaultComposeStrategy
  #                             protocol: args → inh → resolvedCombin → composedPhases
  #
  #     HOOK LIFECYCLE ORDER
  #     ────────────────────
  #     preInputsHook  / preInputsHookFn   → before buildInputs activated
  #     postInputsHook / postInputsHookFn  → after  buildInputs activated
  #     [inherited shellHook: combinFrom shellHooks + top-level shellHook]
  #     preShellHook   / preShellHookFn    → just before interactive shell
  #     postShellHook  / postShellHookFn   → at shell exit / cleanup
  #     shell                              → exec'd last; replaces current process
  #
  #     SHELL OVERRIDE
  #     ──────────────
  #     shell = "zsh"  — exec'd after all hooks; replaces the current process.
  #                      Must exist in PATH or be an absolute path.
  #                      Honoured at the variant level (pdshells passes variant
  #                      attrsets directly to mkDevShell).
  # ════════════════════════════════════════════════════════════════════════════

  mkDevShell = {
    name                  ? "dev-shell",
    buildInputs           ? [],
    nativeBuildInputs     ? [],
    combinFrom            ? [],
    preInputsHook         ? "",
    postInputsHook        ? "",
    preShellHook          ? "",
    postShellHook         ? "",
    shellHook             ? "",
    preInputsHookFn       ? null,
    postInputsHookFn      ? null,
    preShellHookFn        ? null,
    postShellHookFn       ? null,
    shell                 ? null,
    _resolveStrategy      ? resolveStrategy.default,
    _mergeStrategy        ? mergeStrategy.unique,
    _hookComposeStrategy  ? hookComposer.fn-defaultComposeStrategy,
    ...
  } @ args:
    # FULL DATAFLOW PIPELINE — explicit, traceable, maintainable
    args
    |> mkContext
    |> pipeline.fn-init
    |> (pipeline.fn-resolve         _resolveStrategy)
    |> pipeline.fn-extract
    |> (pipeline.fn-merge           _mergeStrategy)
    |> (pipeline.fn-compose         _hookComposeStrategy)
    |> pipeline.fn-build
    |> pipeline.fn-exec;

in {
  # ── Public API ──────────────────────────────────────────────────────────────
  inherit mkDevShell;

  # ── Exported internals — for testing, extension, and pdshells.nix integration
  inherit validate resolveStrategy extractor mergeStrategy hookComposer pipeline;
  inherit HookPhase HookFnField ContextPhase ShellKey;
}
