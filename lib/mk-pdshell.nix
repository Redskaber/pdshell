# @path: ~/projects/configs/nix-config/lib/dev/mk-pdshell.nix
# @author: redskaber
# @datetime: 2026-03-01
# @description: lib::dev::mk-pdshell - Pipeline-driven shell constructor
# - Single Responsibility Principle | Pipeline Architecture | Nix Idiomatic Patterns
# - Designed to complement pdshells.nix ecosystem (validation, naming, strategy patterns)
# - Explicit dataflow with |> operators | Zero side effects | Pure transformations

{ pkgs, ... }:
let
  # == CORE PRINCIPLES ==
  # 1. Data flows left-to-right via |> (explicit transformation chain)
  # 2. Each function: single responsibility, pure, testable
  # 3. Validation at boundaries (fail-fast)
  # 4. Semantic alignment with pdshells.nix patterns (naming, validation, strategy)

  # == VALIDATION MODULE (mirrors pdshells.nix validation philosophy) ==
  validate = {
    # Pipeline-friendly validation primitives (curried for composition)
    fn-assertAttrsList = context: value:
      if pkgs.lib.isList value && pkgs.lib.all pkgs.lib.isAttrs value
      then value
      else throw ''
        VALIDATION FAILED (${context}):
        • Expected: list of attrsets
        • Got: ${builtins.typeOf value}
        Resolution: Ensure combinFrom contains only valid config attrsets or language groups.
      '';

    fn-assertHookResult = hookName: result:
      if result == null then ""
      else if pkgs.lib.isString result then result
      else throw ''
        HOOK CONTRACT VIOLATION (${hookName}):
        • Expected: string or null
        • Got: ${builtins.typeOf result}
        Resolution: Hook functions must return string or null. Complex values require explicit serialization.
      '';
  };
  # Configure identity for the development shell
  devshcid = {
    default-attrKey = "default";
    buildInputs = "buildInputs";
    nativeBuildInputs = "nativeBuildInputs";
    shellHook = "shellHook";
  };

  # == STRATEGY MODULE: CombinFrom Resolution Strategy ==
  # Mirrors pdshells.nix FileProcessStrategy pattern - explicit protocol
  combinStrategy = {
    # Strategy protocol: entry -> resolved config attrset
    fn-resolveEntry = entry:
      (pkgs.lib.isAttrs entry)
      |> (isAttr: if !isAttr then throw "combinFrom entry must be attrset, got: ${builtins.typeOf entry}" else entry)
      |> (e: if builtins.hasAttr devshcid.default-attrKey e then e.default else e)
      |> (cfg: if !(builtins.hasAttr devshcid.buildInputs cfg || builtins.hasAttr devshcid.shellHook cfg)
            then throw "Invalid combinFrom entry: missing shell config keys (${devshcid.buildInputs}/${devshcid.shellHook})"
            else cfg);

    # Full pipeline: validate → resolve → extract
    fn-processCombinFrom = combinFrom:
      combinFrom
      |> (validate.fn-assertAttrsList "COMBINFROM INPUT")
      |> (list: map combinStrategy.fn-resolveEntry list);
  };

  # == EXTRACTOR MODULE: Pure field extraction ==
  extractor = {
    fn-extractField = field: configs:
      configs
      |> (list: map (cfg: cfg.${field} or []) list)
      |> pkgs.lib.concatLists;

    fn-extractHooks = configs:
      configs
      |> (list: map (cfg: {
        shellHook     = cfg.shellHook      or "";
        preInputsHook = cfg.preInputsHook  or "";
        postInputsHook= cfg.postInputsHook or "";
        preShellHook  = cfg.preShellHook   or "";
        postShellHook = cfg.postShellHook  or "";
      }) list);
  };

  # == HOOK MODULE: Pipeline-driven hook composition ==
  hook = {
    # Unified hook execution protocol (mirrors pdshells.nix hook philosophy)
    fn-executeHookFn = fn: hookName:
      (fn == null)
      |> (isNull: if isNull then "" else fn { inherit pkgs; })
      |> (result: validate.fn-assertHookResult hookName result);

    # Compose single hook type: inherited + custom + fn
    fn-composeHook = hookFieldName: hookFnFieldName: inheritedList: customStr: fn:
      inheritedList
      |> pkgs.lib.concatStringsSep "\n"
      |> (inherited: inherited + "\n" + customStr + "\n" + (hook.fn-executeHookFn fn hookFnFieldName))
      |> pkgs.lib.strings.trim;

    # Build full shellHook sections with semantic headers
    fn-buildSection = label: content:
      (content == "")
      |> (isEmpty: if isEmpty then "" else "# === ${label} ===\n${content}");

    fn-assembleShellHook = {
      inheritedShell,
      preInputs,
      postInputs,
      preShell,
      postShell
    }:
      [
        (hook.fn-buildSection "INHERITED SHELLHOOK" inheritedShell)
        (hook.fn-buildSection "PRE-INPUTS HOOK"     preInputs)
        (hook.fn-buildSection "POST-INPUTS HOOK"    postInputs)
        (hook.fn-buildSection "PRE-SHELL HOOK"      preShell)
        (hook.fn-buildSection "POST-SHELL HOOK"     postShell)
      ]
      |> pkgs.lib.filter (s: s != "")
      |> pkgs.lib.concatStringsSep "\n\n";

    fn-execShell = shellHooks: ctx:
      if (ctx.args ? shell && ctx.args.shell != null) then
        # Append AFTER all hooks (exec replaces current process)
        # Note: User must ensure shell is in PATH or absolute path
        shellHooks + "\n\n# === FINAL SHELL OVERRIDE ===\nexec ${ctx.args.shell}"
      else
        shellHooks;

  };

  # == MERGER MODULE: Idempotent input merging ==
  merger = {
    # merge and unique
    fn-mergeInputs = base: extracted:
      (base ++ extracted)
      |> pkgs.lib.unique;
  };

  # == CONTEXT SCHEMA: Explicit data carrier (mirrors pdshells.nix Context pattern) ==
  # Enables pipeline tracing, testing, and extension
  Context = {
    args,              # Original arguments
    resolvedCombin,    # Resolved combinFrom configs
    extractedHooks,    # Normalized hook structures
    mergedInputs,      # Final input lists
    composedHooks,     # Fully composed hook strings
    mkShellParams      # Final parameters for mkShell
  }: {
    args = args;
    resolvedCombin = resolvedCombin;
    extractedHooks = extractedHooks;
    mergedInputs = mergedInputs;    # { buildInputs={...}, nativeBuildInputs={...} }
    composedHooks = composedHooks;  # { preInputs={...}, postInputs={...}, preShell={...}, postShell={...}, inheritedShell={...} }
    mkShellParams = mkShellParams;
  };

  # == PIPELINE STAGES: Pure transformations with explicit contracts ==
  pipeline = {
    # Stage 1: Initialize context with raw inputs
    fn-initContext = args:
      Context {
        args = args;
        resolvedCombin = [];
        extractedHooks = {};
        mergedInputs = {};
        composedHooks = {};
        mkShellParams = {};
      };

    # Stage 2: Resolve and validate combinFrom entries
    fn-resolveCombin = ctx:
      ctx.args.combinFrom or []
      |> combinStrategy.fn-processCombinFrom
      |> (resolved: ctx // { resolvedCombin = resolved; });

    # Stage 3: Extract normalized hook structures
    fn-extractHooks = ctx:
      ctx.resolvedCombin
      |> extractor.fn-extractHooks
      |> (hooks: ctx // { extractedHooks = hooks; });

    # Stage 4: Merge build inputs deterministically
    fn-mergeInputs = ctx:
      let
        buildInputs = merger.fn-mergeInputs
          (ctx.args.buildInputs or [])
          (extractor.fn-extractField devshcid.buildInputs ctx.resolvedCombin);
        nativeBuildInputs = merger.fn-mergeInputs
          (ctx.args.nativeBuildInputs or [])
          (extractor.fn-extractField devshcid.nativeBuildInputs ctx.resolvedCombin);
      in ctx // {
        mergedInputs = {
          inherit buildInputs nativeBuildInputs;
        };
      };

    # Stage 5: Compose all hook types through unified protocol
    fn-composeHooks = ctx:
      let
        inh = ctx.extractedHooks;
        args = ctx.args;
        preInputs = hook.fn-composeHook
          "preInputsHook"
          "preInputsHookFn"
          (map (h: h.preInputsHook) inh)
          (args.preInputsHook   or "")
          (args.preInputsHookFn or null);
        postInputs = hook.fn-composeHook
          "postInputsHook"
          "postInputsHookFn"
          (map (h: h.postInputsHook) inh)
          (args.postInputsHook   or "")
          (args.postInputsHookFn or null);
        preShell = hook.fn-composeHook
          "preShellHook"
          "preShellHookFn"
          (map (h: h.preShellHook) inh)
          (args.preShellHook    or "")
          (args.preShellHookFn  or null);
        postShell = hook.fn-composeHook
          "postShellHook"
          "postShellHookFn"
          (map (h: h.postShellHook) inh)
          (args.postShellHook   or "")
          (args.postShellHookFn or null);
        # sup mkShell origin api
        inheritedShell = extractor.fn-extractField "shellHook" ctx.resolvedCombin
          |> pkgs.lib.concatStringsSep "\n"
          |> (s: s + "\n" + (args.shellHook or ""));
      in ctx // {
        composedHooks = {
          inherit preInputs postInputs preShell postShell inheritedShell;
        };
      };

    # Stage 6: Assemble final mkShell parameters
    fn-buildParams = ctx:
      let
        baseShellHook = hook.fn-assembleShellHook {
          inheritedShell = ctx.composedHooks.inheritedShell;
          preInputs = ctx.composedHooks.preInputs;
          postInputs = ctx.composedHooks.postInputs;
          preShell = ctx.composedHooks.preShell;
          postShell = ctx.composedHooks.postShell;
        };
        shellHook = hook.fn-execShell baseShellHook ctx;
        baseParams = builtins.removeAttrs ctx.args [
          "combinFrom"
          "preInputsHook" "postInputsHook" "preShellHook" "postShellHook" "shellHook"
          "preInputsHookFn" "postInputsHookFn" "preShellHookFn" "postShellHookFn"
          "shell"
        ];
      in ctx // {
        mkShellParams = baseParams // {
          name = ctx.args.name or "dev-shell";
          buildInputs = ctx.mergedInputs.buildInputs;
          nativeBuildInputs = ctx.mergedInputs.nativeBuildInputs;
          inherit shellHook;
        };
      };

    # Stage 7: Final validation and execution
    fn-validateAndExecute = ctx:
      # Cross-stage validation (mirrors pdshells.nix structural validation)
      (ctx.mkShellParams.shellHook != null && pkgs.lib.isString ctx.mkShellParams.shellHook)
      |> (valid: if !valid then throw "SHELLHOOK VALIDATION FAILED: must be string" else true)
      |> (_: pkgs.mkShell ctx.mkShellParams);
  };

  # == PUBLIC API: Single entry point with explicit pipeline ==
  # Mirrors pdshells.nix top-level execution pattern
  mkDevShell = {
    name ? "dev-shell",
    buildInputs ? [],
    nativeBuildInputs ? [],
    combinFrom ? [],
    preInputsHook ? "",
    postInputsHook ? "",
    preShellHook ? "",
    postShellHook ? "",
    shellHook ? "",
    preInputsHookFn ? null,
    postInputsHookFn ? null,
    preShellHookFn ? null,
    postShellHookFn ? null,
    # shell ? null:
    #   Optional final shell override (e.g., "zsh", "/bin/fish", "bash -l")
    #   • Executes AFTER all hooks via `exec` (replaces current process)
    #   • ONLY uses TOP-LEVEL value (combinFrom entries IGNORED for safety)
    #   • If null/omitted: uses mkShell default (typically bash)
    #   • WARNING: Shell must exist in PATH or be absolute path
    #   • EXAMPLE: shell = "zsh";  # Enters zsh after all setup
    shell ? null,
    ...
  } @ args:
    # FULL DATAFLOW PIPELINE: Explicit, traceable, maintainable
    args
    |> pipeline.fn-initContext
    |> pipeline.fn-resolveCombin
    |> pipeline.fn-extractHooks
    |> pipeline.fn-mergeInputs
    |> pipeline.fn-composeHooks
    |> pipeline.fn-buildParams
    |> pipeline.fn-validateAndExecute;

in {
  inherit mkDevShell;
  # Export internals for testing/extensibility (like pdshells.nix modules)
  inherit validate combinStrategy extractor hook merger pipeline;
}


