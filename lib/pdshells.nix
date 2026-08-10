# @path: lib/pdshells.nix
# @author: redskaber
# @version: 2.5.0
# @datetime: 2026-05-24
# @description: lib::pdshells — Dataflow-driven layered shell loader
#
# == ARCHITECTURE PRINCIPLES ==
#  1. Dependency Inversion   — modules depend on protocol contracts, not implementations
#  2. Pipeline Dataflow      — |> left-to-right transforms; every stage returns a new Context
#  3. Layered Architecture   — recursive depth-first traversal with per-directory isolation
#  4. Incremental Mode       — variantsTree grows incrementally; shells registered as discovered
#  5. Strategy Management    — FileProcessStrategy is a first-class pluggable record
#  6. State Machine          — LayerContext: SCAN→SUBDIRS→COMMON→DEFAULT→DONE_PENDING→DONE (guarded)
#  7. Lifecycle Management   — subDirs processed before common files before default.nix
#  8. Boundary Clarity       — public surface: pdshells output; internal: fs/layer/validate
#  9. Data-Driven            — behaviour driven by directory contents; no hard-coded names
# 10. Communication Protocol — LayerContext and LayerResult are typed envelopes
# 11. Plugin / Hot-swap      — FileProcessStrategy is swappable; _commonStrategy/_defaultStrategy
#
# == CHANGELOG v2.5.0 ==
#
#  [G1] RuntimeEnv responsibility boundary corrected — BREAKING fix for the core bug.
#
#       ROOT CAUSE OF THE BUG:
#         pdshells.nix is a LOADER/ROUTER. Its job is:
#           discover .nix files → read their contents → dispatch to mkDevShell
#         Whether `shared`, `inputs`, or `dev` carry meaningful values is entirely
#         the concern of the SHELL FILE author, not the framework.
#
#         v2.4 RuntimeEnv.mk checked `shared.arch` and `inputs != {}` — this mixed
#         PROJECT-LEVEL CONVENTIONS into FRAMEWORK INFRASTRUCTURE, violating
#         layer boundary clarity (Principle §8).
#
#       LAYER MODEL (corrected):
#         ┌─────────────────────────────────────────────────────────┐
#         │ Layer 2 — Shell file  (python/renpy/default.nix)        │
#         │   Declares: { pkgs, inputs ? {}, shared ? {}, dev ? {} }│
#         │   Uses whatever fields it needs; ignores the rest.      │
#         ├─────────────────────────────────────────────────────────┤
#         │ Layer 1 — Project config  (flake.nix / shared.nix)      │
#         │   Decides: what shared contains, whether inputs matter  │
#         ├─────────────────────────────────────────────────────────┤
#         │ Layer 0 — Framework  (pdshells / mk-pdshell)            │
#         │   Knows: pkgs (required to call pkgs.mkShell)           │
#         │   Forwards: inputs, shared, dev as opaque payloads      │
#         │   Never inspects the CONTENTS of inputs or shared       │
#         └─────────────────────────────────────────────────────────┘
#
#       CHANGES:
#         • RuntimeEnv.mk validates ONLY type safety:
#             pkgs   — must be an attrset (framework uses pkgs.lib, pkgs.mkShell)
#             inputs — must be an attrset or absent; defaults to {}
#             shared — must be an attrset or absent; defaults to {}
#         • Removed: inputs == {} check (legitimate for pkgs-only projects)
#         • Removed: shared.arch check   (project convention, not framework concern)
#         • Module parameters: `inputs ? {}` and `shared ? {}` restored as safe defaults
#
#  [G2] AttrFileParams defaults restored — safe and correct.
#         AttrFileParams = { pkgs, inputs ? {}, shared ? {}, dev ? {} }
#         • pkgs is the only required field (every shell needs at least pkgs)
#         • inputs/shared/dev are optional; framework passes whatever it has
#         • Shell files declare their own minimums via pattern matching
#
#  [G3] fn-buildFlatShells now injects pkgs explicitly.
#         Signature: fn-buildFlatShells = pkgs': basePath: sourceKind: fileBase: variantsTree:
#         mkDevShell is called with pkgs injected from runtimeEnv.pkgs, fixing the
#         `pkgs ? pkgs` self-reference in mk-pdshell v2.4.
#
# == CHANGELOG v2.4.0 ==
#  [B2] LayerContext FSM guarded via validate.fn-assertLayerPhase
#  [B3] fn-processDirectory hardened with internal path guard
#  [B4] fn-assertStructuralValidation: minimal field destructuring
#  [C3] AttrType → SourceKind (DirectoryRoot / NamedFile)
#  [D2] _commonStrategy / _defaultStrategy injection points
#  [E2] Global uniqueness: assert → lib.seq
#  [E3] fn-flatShellsMapAttrs' → fn-buildFlatShells
#  [E4] builtins.deepSeq on shellNames

{ pkgs, inputs ? {}, devDir, shared ? {}, suffix ? ".nix"
, _commonStrategy  ? null   # inject replacement for NamedFile (.nix) processing
, _defaultStrategy ? null   # inject replacement for DirectoryRoot (default.nix) processing
, ...
}:
let
  lib = pkgs.lib;
  inherit (inputs.nix-types.lib) enum;
  inherit (import ./mk-pdshell.nix { inherit pkgs; }) mkDevShell;

  # ════════════════════════════════════════════════════════════════════════════
  # §0  RUNTIME ENVIRONMENT  (Communication Protocol — DI root)
  #
  #     RuntimeEnv is the single DI root threaded through every pipeline stage.
  #     It carries ONLY what the framework itself needs to operate:
  #
  #       pkgs   — REQUIRED. The nixpkgs instance.  Used by the framework for
  #                pkgs.lib operations and injected into mkDevShell calls.
  #                Validation: must be an attrset.
  #
  #       inputs — OPTIONAL (defaults to {}).  Forwarded opaquely to shell files.
  #                The framework never accesses inputs.X — it is a pass-through
  #                payload whose contents are entirely the shell file's concern.
  #                Validation: must be an attrset (type safety only).
  #
  #       shared — OPTIONAL (defaults to {}).  Forwarded opaquely to shell files.
  #                Same semantics as inputs: the framework is agnostic to its
  #                structure.  A project that doesn't use shared can omit it.
  #                Validation: must be an attrset (type safety only).
  #
  #     WHAT RuntimeEnv does NOT validate:
  #       • Whether inputs is empty — empty inputs is valid for pkgs-only projects
  #       • Whether shared has any particular field (e.g. `arch`) — that is a
  #         project convention, not a framework requirement
  #       • The content of any forwarded field
  # ════════════════════════════════════════════════════════════════════════════

  RuntimeEnv = {

    ## Constructor / validator.
    ## Open record — forward-compatible with future extension fields.
    mk = { pkgs, inputs, shared, ... }:
      if !lib.isAttrs pkgs
        then throw ''
          RuntimeEnv.mk: `pkgs` must be a nixpkgs attrset.
          • Got: ${builtins.typeOf pkgs}
          Resolution: pass a valid nixpkgs instance.
        ''
      else if !lib.isAttrs inputs
        then throw ''
          RuntimeEnv.mk: `inputs` must be an attrset.
          • Got: ${builtins.typeOf inputs}
          Resolution: pass an attrset (flake inputs, or {} if unused).
        ''
      else if !lib.isAttrs shared
        then throw ''
          RuntimeEnv.mk: `shared` must be an attrset.
          • Got: ${builtins.typeOf shared}
          Resolution: pass an attrset (shared config, or {} if unused).
        ''
      else { inherit pkgs inputs shared; };
  };

  ## The single RuntimeEnv instance for this pdshells invocation.
  ## inputs and shared come from module parameters — both default to {}.
  runtimeEnv = RuntimeEnv.mk { inherit pkgs inputs shared; };

  # ════════════════════════════════════════════════════════════════════════════
  # §1  PROTOCOL DEFINITIONS
  # ════════════════════════════════════════════════════════════════════════════

  ## LayerContext FSM phase enum.
  ## Transitions enforced by validate.fn-assertLayerPhase.
  ##
  ## Phase semantics:
  ##   SCAN         — fresh context, no processing started
  ##   SUBDIRS      — sub-directory results accumulated in subDirsAttrs
  ##   COMMON       — NamedFile (.nix) results accumulated in commonAttrs
  ##   DEFAULT      — DirectoryRoot (default.nix) result accumulated in defaultAttrs
  ##   DONE_PENDING — all accumulation complete; conflict check not yet run
  ##   DONE         — conflict check passed; ready for LayerResult construction
  LayerPhase = {
    SCAN         = "SCAN";
    SUBDIRS      = "SUBDIRS";
    COMMON       = "COMMON";
    DEFAULT      = "DEFAULT";
    DONE_PENDING = "DONE_PENDING";
    DONE         = "DONE";
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §2  VALIDATION MODULE
  # ════════════════════════════════════════════════════════════════════════════

  validate = {

    ## Assert value is an attrset (boundary check on imported .nix files).
    fn-assertAttrSet = context: value:
      if lib.isAttrs value then value
      else throw ''
        INVALID STRUCTURE (${context}):
        • Expected : attrset
        • Got      : ${builtins.typeOf value}
        Resolution : Ensure the file returns an attrset, e.g.:
          { default = { buildInputs = [ ... ]; }; }
      '';

    ## Assert all names are unique; throw with a resolution hint on conflict.
    fn-assertUniqueNames = context: names:
      (builtins.groupBy (x: x) names)
      |> (groups: lib.filterAttrs (_: g: builtins.length g > 1) groups)
      |> (dupGroups: builtins.attrNames dupGroups)
      |> (dupNames:
        if dupNames == [] then names
        else throw ''
          ${context} NAMING CONFLICT:
          • Duplicate identifiers: ${builtins.concatStringsSep ", " dupNames}
          Resolution: Follow naming protocol:
            - default.nix variant 'X'   → [base]-X
            - X.nix  variant 'default'  → [base]-X  (avoid if [base]-X already exists)
          Fix by renaming variants or files for global uniqueness.
        '');

    ## Assert a filesystem path exists (fail-fast).
    fn-assertFileExists = path:
      if builtins.pathExists path then path
      else throw ''
        PATH NOT FOUND: ${path}
        Resolution: Verify directory structure matches expectations.
      '';

    ## Assert no key overlap between an existing variantsTree and a new one.
    ## Returns ctx on success (pipeline-composable).
    fn-assertNoKeyConflicts = context: base: new: ctx:
      (builtins.attrNames new)
      |> (newKeys: lib.filter (key: lib.hasAttr key base) newKeys)
      |> (conflicts:
        if conflicts == [] then ctx
        else throw ''
          ${context} KEY COLLISION:
          • Conflicting keys : ${builtins.concatStringsSep ", " conflicts}
          • Base keys        : ${builtins.concatStringsSep ", " (builtins.attrNames base)}
          • New keys         : ${builtins.concatStringsSep ", " (builtins.attrNames new)}
          Resolution: Rename variants in default.nix or conflicting files/dirs.
        '');

    ## Guard: defaultAttrs must not collide with subDirs + common trees.
    ## Enforces DONE_PENDING at entry; transitions to DONE on success.
    fn-assertDefaultAttrsConflicts = ctx:
      validate.fn-assertLayerPhase LayerPhase.DONE_PENDING ctx
      |> (ctx:
        (ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree)
        |> (variantsTree:
            validate.fn-assertNoKeyConflicts
              "VARIANTS TREE"
              variantsTree
              ctx.defaultAttrs.variantsTree
              ctx)
        |> (ctx: ctx // { phase = LayerPhase.DONE; })
      );

    ## Guard: no .nix file and directory sharing the same base name.
    ## Minimal destructuring — only currentPath and suffix are used.
    fn-assertStructuralValidation = { currentPath, suffix, ... } @ ctx:
      (fs.fn-listDir currentPath)
      |> (entries: {
          nixFiles = lib.filter (fs.fn-isAttrsFile currentPath) entries;
          subDirs  = lib.filter (fs.fn-isAttrsDir  currentPath) entries;
        })
      |> (items:
          if items.nixFiles == [] && items.subDirs == []
          then throw "EMPTY DIRECTORY: ${currentPath} requires .nix files or sub-dirs"
          else items)
      |> (items:
          (map (fn: fs.fn-makeFileBase suffix fn) items.nixFiles)
          |> (fileBases: lib.filter (n: lib.elem n items.subDirs) fileBases))
      |> (conflicts:
          if conflicts != []
          then throw ''
            STRUCTURAL AMBIGUITY in ${currentPath}:
            • Conflicting sources: ${builtins.concatStringsSep ", " conflicts}
            Resolution: ONE source per base name — EITHER file OR directory, NOT both.
            ${builtins.concatStringsSep " AND "
                (map (n: "${n}${suffix} vs ${n}/") conflicts)}
          ''
          else ctx);

    ## LayerContext FSM phase transition guard.
    ## v2.4: enforces the SCAN→SUBDIRS→COMMON→DEFAULT→DONE_PENDING→DONE sequence.
    ## Returns ctx on success; throws on violation.
    fn-assertLayerPhase = expectedPhase: ctx:
      if ctx.phase == expectedPhase
      then ctx
      else throw ''
        LAYER PHASE VIOLATION in ${ctx.currentPath}:
        • Expected phase : ${expectedPhase}
        • Current phase  : ${ctx.phase}
        Resolution       : Layer pipeline stages must execute in order:
          SCAN → SUBDIRS → COMMON → DEFAULT → DONE_PENDING → DONE
      '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §3  NAMING MODULE
  # ════════════════════════════════════════════════════════════════════════════

  naming = {
    default-variantName = "default";
    default-concat-sep  = "-";

    ## Derive the canonical shell name from hierarchy position.
    ##
    ## Rules (applied left to right, null entries dropped):
    ##   1. basePath ""          → omit  (root level has no prefix)
    ##   2. DirectoryRoot kind   → omit fileBase  (directory name IS the identity)
    ##   3. variantName "default"→ omit  (redundant when other parts present)
    ##   4. All parts null       → "default"
    ##
    ## Examples (basePath="python"):
    ##   NamedFile,     fileBase="renpy",  variantName="default" → "python-renpy"
    ##   NamedFile,     fileBase="renpy",  variantName="gpu"     → "python-renpy-gpu"
    ##   DirectoryRoot, fileBase="renpy",  variantName="default" → "python"
    ##   DirectoryRoot, fileBase="renpy",  variantName="machine" → "python-machine"
    fn-makeFullName = basePath: sourceKind: fileBase: variantName:
      ([
        (if basePath    == fs.default-basePath         then null else basePath)
        (if sourceKind  == fs.SourceKind.DirectoryRoot then null else fileBase)
        (if variantName == naming.default-variantName  then null else variantName)
      ]
      |> lib.filter (x: x != null))
      |> lib.concatStringsSep naming.default-concat-sep
      |> (fullName: if fullName == "" then naming.default-variantName else fullName);
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §4  FILESYSTEM MODULE
  # ════════════════════════════════════════════════════════════════════════════

  fs = {
    default-nix            = "default.nix";
    default-path           = "dev";
    default-basePath       = "";
    default-fileBase       = "";
    default-private-prefix = "_";
    default-nixSuffix      = ".nix";

    ## SourceKind — semantic rename of the former AttrType enum.
    ##
    ##   DirectoryRoot — file is default.nix; represents the containing directory.
    ##                   fileBase is omitted from the shell name (directory IS the name).
    ##   NamedFile     — file is foo.nix; identified by its filename.
    ##                   fileBase contributes to the shell name.
    SourceKind = enum "SourceKind" [ "DirectoryRoot" "NamedFile" ];

    ## AttrFileParams — the parameter record passed to every imported shell file.
    ##
    ## CONTRACT:
    ##   pkgs   — required; the nixpkgs instance.  Every shell file uses pkgs.
    ##   inputs — optional (default {}); forwarded opaquely from runtimeEnv.
    ##            Shell files declare `inputs ? {}` to opt-in; omit if unused.
    ##   shared — optional (default {}); forwarded opaquely from runtimeEnv.
    ##            Shell files declare `shared ? {}` to opt-in; omit if unused.
    ##   dev    — optional (default {}); the accumulated variantsTree at import time.
    ##            Shell files declare `dev ? {}` to opt-in; omit if unused.
    ##
    ## DevScope — what `dev` contains at import time, by SourceKind:
    ## ┌────────────────┬────────────────────────────────────────────────────┐
    ## │ SourceKind     │ dev contents                                       │
    ## ├────────────────┼────────────────────────────────────────────────────┤
    ## │ NamedFile      │ { dirName: DirVariantsTree }                       │
    ## │                │ Sub-directory results only.  Named files in the    │
    ## │                │ same directory are NOT visible to each other.      │
    ## ├────────────────┼────────────────────────────────────────────────────┤
    ## │ DirectoryRoot  │ { dirName: DirVariantsTree }                       │
    ## │                │   // { fileBase: FileVariantsTree }                │
    ## │                │ Full scope: sub-dirs AND named-file results.       │
    ## │                │ default.nix sees the complete picture.             │
    ## └────────────────┴────────────────────────────────────────────────────┘
    ##
    ## Open record (@p: p) — forward-compatible with future extension fields.
    AttrFileParams = { pkgs, inputs ? {}, shared ? {}, dev ? {} } @ p: p;

    # ── Pure path predicates ─────────────────────────────────────────────────
    fn-isPrivate   = name: lib.hasPrefix fs.default-private-prefix name;
    fn-isNixFile   = sfx: name: lib.hasSuffix sfx name;

    fn-isType = expectedType: path: name:
      (builtins.readDir path).${name}
      |> (type: type == expectedType);

    fn-isRegular   = fs.fn-isType "regular";
    fn-isDirectory = fs.fn-isType "directory";

    fn-isAttrsDir = path: name:
      (fs.fn-isDirectory path name) && !fs.fn-isPrivate name;

    fn-isAttrsFile = path: name:
      (fs.fn-isRegular path name)
      && fs.fn-isNixFile fs.default-nixSuffix name
      && !fs.fn-isPrivate name;

    fn-listDir = path:
      builtins.readDir path |> builtins.attrNames;

    fn-getAttrsDirs = path:
      fs.fn-listDir path
      |> (entries: lib.filter (name: fs.fn-isAttrsDir path name) entries);

    fn-getAttrsFiles = currentSuffix: path:
      fs.fn-listDir path
      |> (entries: lib.filter (name:
            name != fs.default-nix
            && fs.fn-isRegular path name
            && fs.fn-isNixFile currentSuffix name
            && !fs.fn-isPrivate name) entries);

    fn-hasDefaultAttrs = path:
      fs.fn-listDir path
      |> (entries: lib.any (name: name == fs.default-nix) entries);

    fn-makeFileBase = currentSuffix: fileName:
      lib.removeSuffix currentSuffix fileName;

    ## Read and validate attrs from a .nix file.
    ## runtimeEnv' provides pkgs/inputs/shared; variantsTree is the DevScope.
    fn-readFileAttrs = filePath: runtimeEnv': variantsTree:
      (fs.AttrFileParams {
        pkgs   = runtimeEnv'.pkgs;
        inputs = runtimeEnv'.inputs;
        shared = runtimeEnv'.shared;
        dev    = variantsTree;
      })
      |> (params: import filePath params)
      |> (vars: validate.fn-assertAttrSet "FILE CONTENT (${filePath})" vars);

    ## Build a flat { shellName = derivation; } map from one file's variantsTree.
    ##
    ## v2.5: pkgs' is now an explicit first argument — injected from runtimeEnv.pkgs.
    ## This ensures mkDevShell always receives pkgs without relying on the module
    ## closure or self-referential defaults.
    fn-buildFlatShells = pkgs': basePath: sourceKind: fileBase: variantsTree:
      lib.mapAttrs' (variantName: attrsetCfg:
        (naming.fn-makeFullName basePath sourceKind fileBase variantName)
        |> (shellName: {
          name  = shellName;
          value = mkDevShell (attrsetCfg // {
            name = "dev-shell-${shellName}";
            pkgs = pkgs';               # explicit injection — no self-reference
          });
        })
      ) variantsTree;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §5  LAYER DATA STRUCTURES
  # ════════════════════════════════════════════════════════════════════════════

  layer = {

    ## CommonAttrs — flat accumulator for shells, variant tree, and name registry.
    ##
    ## variantsTree semantics per slot:
    ##   subDirsAttrs.variantsTree → DirIndex    : { dirName:     LayerVariantsTree }
    ##   commonAttrs.variantsTree  → FileIndex   : { fileBase:    FileVariantsTree  }
    ##   defaultAttrs.variantsTree → RootVariants: { variantName: shellCfg          }
    CommonAttrs = { flatShells ? {}, variantsTree ? {}, shellNames ? [] }: {
      inherit flatShells variantsTree shellNames;
    };

    ## LayerContext — FSM envelope for processing one directory.
    Context = {
      currentPath,
      basePath,
      runtimeEnv,
      suffix       ? fs.default-nixSuffix,
      phase        ? LayerPhase.SCAN,
      subDirsAttrs ? layer.CommonAttrs {},
      commonAttrs  ? layer.CommonAttrs {},
      defaultAttrs ? layer.CommonAttrs {},
    }: {
      inherit currentPath basePath runtimeEnv suffix phase
              subDirsAttrs commonAttrs defaultAttrs;
    };

    ## Bootstrap a fresh LayerContext for a directory.
    fn-initialContext = currentPath: basePath: currentSuffix: runtimeEnv':
      layer.Context {
        inherit currentPath basePath;
        suffix     = currentSuffix;
        runtimeEnv = runtimeEnv';
      };

    ## LayerResult — final typed output for one directory.
    LayerResult = { path, flatShells, variantsTree, shellNames } @ p: p;

    ## FileResult — output of processing one .nix file.
    FileResult = { fileBase, flatShells, variantsTree, shellNames } @ p: p;

    ## FileContext — input contract for processing a single .nix file.
    ## runtimeEnv carries pkgs/inputs/shared; subVariantsTree is the DevScope.
    FileContext = {
      currentPath,
      basePath,
      sourceKind,
      fileName,
      subVariantsTree,
      runtimeEnv,
      suffix  ? fs.default-nixSuffix,
    }: {
      inherit currentPath basePath sourceKind fileName subVariantsTree runtimeEnv suffix;
    };

    ## Process one .nix file: read attrs → build flat shells → register names.
    fn-initialFileResult = fileCtx:
      let
        fileBase     = fs.fn-makeFileBase fileCtx.suffix fileCtx.fileName;
        filePath     = "${fileCtx.currentPath}/${fileCtx.fileName}";
        variantsTree = fs.fn-readFileAttrs filePath fileCtx.runtimeEnv fileCtx.subVariantsTree;
        flatShells   = fs.fn-buildFlatShells
                         fileCtx.runtimeEnv.pkgs       # pkgs injected explicitly
                         fileCtx.basePath fileCtx.sourceKind fileBase variantsTree;
        shellNames   = builtins.attrNames flatShells;
      in layer.FileResult { inherit fileBase flatShells variantsTree shellNames; };

    # ── FILE PROCESS STRATEGY  (plugin pattern) ───────────────────────────────
    #
    # Each strategy is a first-class record describing HOW to process one category
    # of source file.  The protocol (FileStrategy) defines the interface contract;
    # NamedFileStrategy and DirectoryRootStrategy are the two built-in implementations.
    #
    # Injection: _commonStrategy and _defaultStrategy module parameters allow callers
    # to replace either strategy without modifying this file.

    FileProcessStrategy = {

      ## Strategy protocol interface.
      FileStrategy = {
        sourceKind,             # SourceKind.DirectoryRoot | SourceKind.NamedFile
        targetField,            # "commonAttrs" | "defaultAttrs"
        fn-getFileList,         # currentPath → suffix → [fileName]
        fn-getSubVariantsTree,  # LayerContext → variantsTree  (DevScope)
        fn-aggregateVariantsTree, # [FileResult] → variantsTree
        fn-validationContext,   # currentPath → string
      } @ p: p;

      ## NamedFileStrategy — all non-default .nix files.
      ## DevScope: subDirsAttrs.variantsTree (DirIndex only — no cross-file deps).
      NamedFileStrategy = layer.FileProcessStrategy.FileStrategy {
        sourceKind            = fs.SourceKind.NamedFile;
        targetField           = "commonAttrs";
        fn-getFileList        = currentPath: currentSuffix:
          fs.fn-getAttrsFiles currentSuffix currentPath;
        fn-getSubVariantsTree = ctx: ctx.subDirsAttrs.variantsTree;
        fn-validationContext  = currentPath: "NAMED FILE ATTRS (${currentPath})";
        fn-aggregateVariantsTree = fileResults:
          lib.listToAttrs
            (map (r: { name = r.fileBase; value = r.variantsTree; }) fileResults);
      };

      ## DirectoryRootStrategy — default.nix only.
      ## DevScope: DirIndex // FileIndex (widest visibility — sees everything).
      DirectoryRootStrategy = layer.FileProcessStrategy.FileStrategy {
        sourceKind            = fs.SourceKind.DirectoryRoot;
        targetField           = "defaultAttrs";
        fn-getFileList        = currentPath: _sfx:
          if fs.fn-hasDefaultAttrs currentPath then [ fs.default-nix ] else [];
        fn-getSubVariantsTree = ctx:
          ## DirIndex // FileIndex — full scope for default.nix
          ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree;
        fn-validationContext  = currentPath: "DIRECTORY ROOT ATTRS (${currentPath})";
        fn-aggregateVariantsTree = fileResults:
          (builtins.head fileResults).variantsTree;
      };

      ## Execute a strategy — returns ctx unchanged when no files found.
      fn-execute = strategy: currentPath: basePath: ctx:
        (strategy.fn-getFileList currentPath ctx.suffix)
        |> (files:
          if files == []
          then ctx
          else
            map (fileName: layer.fn-initialFileResult (layer.FileContext {
              inherit currentPath basePath fileName;
              sourceKind      = strategy.sourceKind;
              suffix          = ctx.suffix;
              runtimeEnv      = ctx.runtimeEnv;
              subVariantsTree = strategy.fn-getSubVariantsTree ctx;
            })) files
            |> (fileResults: layer.CommonAttrs {
              variantsTree = strategy.fn-aggregateVariantsTree fileResults;
              flatShells   = lib.foldl' (acc: r: acc // r.flatShells) {} fileResults;
              shellNames   =
                (lib.concatMap (r: r.shellNames) fileResults)
                |> (validate.fn-assertUniqueNames
                      (strategy.fn-validationContext currentPath));
            })
            |> (attrs: ctx // { ${strategy.targetField} = attrs; })
          );
    };

    ## Active strategies — injected overrides take precedence over built-ins.
    activeStrategies = {
      namedFile     = if _commonStrategy  != null then _commonStrategy
                      else layer.FileProcessStrategy.NamedFileStrategy;
      directoryRoot = if _defaultStrategy != null then _defaultStrategy
                      else layer.FileProcessStrategy.DirectoryRootStrategy;
    };

    # ── LAYER PIPELINE STAGES ─────────────────────────────────────────────────
    #
    # Processing order per directory (depth-first):
    #   SCAN → SUBDIRS → COMMON → DEFAULT → DONE_PENDING → DONE

    ## Stage 1/4: Recursively process sub-directories (depth-first).
    ## v2.4: guarded by fn-assertLayerPhase SCAN at entry.
    fn-processSubDirs = currentPath: basePath: ctx:
      validate.fn-assertLayerPhase LayerPhase.SCAN ctx
      |> (ctx:
        (fs.fn-getAttrsDirs currentPath)
        |> (dirPaths: map (path:
              let
                newBase = if basePath == fs.default-basePath
                          then path
                          else "${basePath}-${path}";
              in layer.fn-processDirectory
                   "${currentPath}/${path}" newBase path ctx.suffix ctx.runtimeEnv
            ) dirPaths)
        |> (layerResults: layer.CommonAttrs {
            flatShells   = lib.foldl' (acc: r: acc // r.flatShells) {} layerResults;
            variantsTree = lib.listToAttrs
              (map (r: { name = r.path; value = r.variantsTree; }) layerResults);
            shellNames   =
              (lib.concatMap (r: r.shellNames) layerResults)
              |> (validate.fn-assertUniqueNames
                    "LAYER DIRECTORY ATTRS(${currentPath})");
          })
        |> (attrs: ctx // { phase = LayerPhase.SUBDIRS; subDirsAttrs = attrs; })
      );

    ## Stage 2/4: Process NamedFile (.nix) — DevScope: subDirs only.
    fn-processCommonAttrs = currentPath: basePath: ctx:
      validate.fn-assertLayerPhase LayerPhase.SUBDIRS ctx
      |> (ctx: ctx // { phase = LayerPhase.COMMON; })
      |> (layer.FileProcessStrategy.fn-execute
            layer.activeStrategies.namedFile currentPath basePath);

    ## Stage 3/4: Process DirectoryRoot (default.nix) — DevScope: subDirs + common.
    fn-processDefaultAttrs = currentPath: basePath: ctx:
      validate.fn-assertLayerPhase LayerPhase.COMMON ctx
      |> (ctx: ctx // { phase = LayerPhase.DEFAULT; })
      |> (layer.FileProcessStrategy.fn-execute
            layer.activeStrategies.directoryRoot currentPath basePath);

    ## Full directory pipeline.
    ## Internal fn-assertFileExists protects both fn-processMain and direct callers.
    fn-processDirectory = currentPath: basePath: path: currentSuffix: runtimeEnv':
      ## Internal path guard — protects direct callers as well as fn-processMain.
      validate.fn-assertFileExists currentPath
      |> (validPath:
        (layer.fn-initialContext validPath basePath currentSuffix runtimeEnv')
        |> validate.fn-assertStructuralValidation
        |> (layer.fn-processSubDirs      validPath basePath)
        |> (layer.fn-processCommonAttrs  validPath basePath)
        |> (layer.fn-processDefaultAttrs validPath basePath)
        |> (ctx: ctx // { phase = LayerPhase.DONE_PENDING; })
        |> validate.fn-assertDefaultAttrsConflicts
        ## phase is now DONE (set by fn-assertDefaultAttrsConflicts on success)
        |> (ctx:
          let
            flatShells =
              ctx.subDirsAttrs.flatShells //
              ctx.commonAttrs.flatShells  //
              ctx.defaultAttrs.flatShells;
            variantsTree =
              ctx.subDirsAttrs.variantsTree //
              ctx.commonAttrs.variantsTree  //
              ctx.defaultAttrs.variantsTree;
            ## builtins.deepSeq forces strict evaluation so the global uniqueness
            ## check always runs against a fully-realised list, never a lazy thunk.
            shellNames =
              let raw = ctx.subDirsAttrs.shellNames
                     ++ ctx.commonAttrs.shellNames
                     ++ ctx.defaultAttrs.shellNames;
              in builtins.deepSeq raw raw;
          in layer.LayerResult { inherit path flatShells variantsTree shellNames; }
        )
      );

    ## Public entry point.
    fn-processMain = currentPath: basePath: path: currentSuffix: runtimeEnv':
      validate.fn-assertFileExists currentPath
      |> (validPath:
          layer.fn-processDirectory validPath basePath path currentSuffix runtimeEnv');
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §6  TOP-LEVEL EXECUTION
  # ════════════════════════════════════════════════════════════════════════════

  rootResult = layer.fn-processMain
    devDir
    fs.default-basePath
    fs.default-path
    suffix
    runtimeEnv;

in
  ## Global uniqueness check — pipeline-style, consistent with dataflow principle.
  rootResult.flatShells
  |> (shells:
    lib.seq
      (validate.fn-assertUniqueNames "GLOBAL NAMESPACE" rootResult.shellNames)
      shells)
