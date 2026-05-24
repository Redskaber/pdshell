# @path: ~/projects/configs/nix-config/lib/dev/pdshells.nix
# @author: redskaber
# @version: 2.4.0
# @datetime: 2026-05-24
# @description: lib::dev::pdshells — Dataflow-driven layered shell loader
#
# == ARCHITECTURE PRINCIPLES ==
#  1. Dependency Inversion   — modules depend on protocol contracts, not implementations
#  2. Pipeline Dataflow      — |> left-to-right transforms; every stage returns a new Context
#  3. Layered Architecture   — recursive depth-first traversal with per-directory isolation
#  4. Incremental Mode       — variantsTree grows incrementally; shells registered as discovered
#  5. Strategy Management    — FileProcessStrategy is a first-class pluggable record
#  6. State Machine          — LayerContext transitions: SCAN→SUBDIRS→COMMON→DEFAULT→DONE (guarded)
#  7. Lifecycle Management   — subDirs processed before common files before default.nix
#  8. Boundary Clarity       — public surface: pdshells output; internal: fs/layer/validate
#  9. Data-Driven            — behaviour driven by directory contents; no hard-coded names
# 10. Communication Protocol — LayerContext and LayerResult are typed envelopes
# 11. Plugin / Hot-swap      — combinFrom entries are composable plugins; strategies are swappable
#
# == CHANGELOG v2.4.0 ==
#
#  [A3] DevScope protocol — `dev` field semantics now documented and enforced.
#       The visible scope of `dev` differs by AttrType (now called SourceKind):
#         NamedFile      dev = { dirName: DirVariantsTree }            (subDirs only)
#         DirectoryRoot  dev = { dirName: … } // { fileBase: … }       (subDirs + common)
#       Each FileProcessStrategy documents its fn-getSubVariantsTree contract explicitly.
#
#  [A4] RuntimeEnv.mk now detects `inputs == {}` — surfaces the silent-empty-inputs bug
#       as a hard evaluation error rather than letting downstream files fail mysteriously.
#
#  [A5] RuntimeEnv.mk validates `shared` has at minimum the `arch` sub-attrset,
#       because `shared.arch.tag` is the universal selector used across all shell files.
#       Validation is project-aware but avoids over-specifying — only `arch` is required.
#
#  [B2] LayerContext FSM is now guarded — LayerPhase protocol constants introduced,
#       `validate.fn-assertLayerPhase` enforces transitions at every stage boundary:
#         fn-processSubDirs      checks SCAN
#         fn-processCommonAttrs  checks SUBDIRS
#         fn-processDefaultAttrs checks COMMON
#         fn-assertDefaultAttrsConflicts checks DEFAULT
#         LayerResult construction checks DONE_PENDING
#
#  [B3] fn-processDirectory is now hardened — it performs fn-assertFileExists
#       internally, so direct callers (e.g. tests) are also protected.
#       fn-processMain retains its role as the public entry point with clear semantics.
#
#  [B4] fn-assertStructuralValidation decoupled — minimal field destructuring
#       `{ currentPath, suffix, ... } @ ctx` makes the dependency surface explicit.
#
#  [C3] AttrType renamed for semantic clarity:
#         Default → DirectoryRoot  (default.nix represents the directory identity)
#         Common  → NamedFile      (foo.nix is identified by its filename)
#       Naming rule: skip fileBase when attrType == DirectoryRoot (directory IS the name).
#
#  [D2] Strategy injection points exposed — callers may override the file-processing
#       strategies via `_commonStrategy` and `_defaultStrategy` module parameters.
#
#  [E2] Global uniqueness check converted from `assert` to pipeline-style `lib.seq`.
#
#  [E3] `fn-flatShellsMapAttrs'` renamed to `fn-buildFlatShells`.
#
#  [E4] `shellNames` strict evaluation guaranteed — `builtins.deepSeq` forces the
#       names list at LayerResult construction time so the global uniqueness check
#       always runs against a fully-realised list, not a lazy thunk.


{ pkgs, inputs, devDir, shared ? {}, suffix ? ".nix"
, _commonStrategy  ? null   # override FileProcessStrategy for NamedFile (.nix) files
, _defaultStrategy ? null   # override FileProcessStrategy for DirectoryRoot (default.nix)
, ...
}:
let
  lib = pkgs.lib;
  inherit (inputs.nix-types.enum) enum;
  inherit (import ./mk-pdshell.nix { inherit pkgs; }) mkDevShell;

  # ════════════════════════════════════════════════════════════════════════════
  # §0  RUNTIME ENVIRONMENT  (Communication Protocol — DI root)
  #
  #     Single explicit record assembled once from the module parameters and
  #     threaded through every downstream context.  No stage may capture
  #     `pkgs`, `inputs`, or `shared` from the outer closure — all access
  #     must go through `runtimeEnv`.
  #
  #     Validation contract:
  #       • pkgs    — must be an attrset (nixpkgs instance)
  #       • inputs  — must be a non-empty attrset (flake inputs); {} → hard error
  #       • shared  — must be an attrset containing `arch` sub-attrset;
  #                   `shared.arch.tag` is the universal system selector
  # ════════════════════════════════════════════════════════════════════════════

  RuntimeEnv = {

    ## Protocol constants for field names — no bare strings in validation logic.
    Field = {
      pkgs   = "pkgs";
      inputs = "inputs";
      shared = "shared";
      arch   = "arch";
    };

    ## Constructor / validator.
    ## Open record (`@ env: …`) — forward-compatible with future extension fields.
    mk = { pkgs, inputs, shared, ... } @ env:
      ## pkgs: must be an attrset
      if !lib.isAttrs pkgs
        then throw ''
          RuntimeEnv.mk: `pkgs` must be a nixpkgs attrset.
          • Got: ${builtins.typeOf pkgs}
        ''
      ## inputs: must be a non-empty attrset
      else if !lib.isAttrs inputs
        then throw ''
          RuntimeEnv.mk: `inputs` must be an attrset (flake inputs).
          • Got: ${builtins.typeOf inputs}
          Resolution: pass the flake `inputs` attrset directly.
        ''
      else if inputs == {}
        then throw ''
          RuntimeEnv.mk: `inputs` is an empty attrset {}.
          • This usually means the caller forgot to forward the flake inputs.
          Resolution: ensure `inputs` is passed from the flake outputs function:
            outputs = { self, nixpkgs, ... } @ inputs: { ... }
                                               ^^^^^^^
        ''
      ## shared: must be an attrset with `arch` sub-attrset
      else if !lib.isAttrs shared
        then throw ''
          RuntimeEnv.mk: `shared` must be an attrset.
          • Got: ${builtins.typeOf shared}
        ''
      else if !builtins.hasAttr RuntimeEnv.Field.arch shared
        then throw ''
          RuntimeEnv.mk: `shared` is missing required field `arch`.
          • `shared.arch.tag` is used throughout shell files as the system selector.
          • Present fields: ${builtins.concatStringsSep ", " (builtins.attrNames shared)}
          Resolution: ensure `shared` is the project's shared config attrset, not a
          partial or empty value.
        ''
      else { inherit pkgs inputs shared; };
  };

  ## The single RuntimeEnv instance for this pdshells invocation.
  runtimeEnv = RuntimeEnv.mk { inherit pkgs inputs shared; };

  # ════════════════════════════════════════════════════════════════════════════
  # §1  PROTOCOL DEFINITIONS
  # ════════════════════════════════════════════════════════════════════════════

  ## LayerContext FSM phase enum.
  ## v2.4: transitions are now enforced by validate.fn-assertLayerPhase.
  ##
  ## Phase semantics:
  ##   SCAN         — fresh context, no processing started
  ##   SUBDIRS      — sub-directory results accumulated in subDirsAttrs
  ##   COMMON       — NamedFile results accumulated in commonAttrs
  ##   DEFAULT      — DirectoryRoot result accumulated in defaultAttrs
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

    ## Guard: defaultAttrs variantsTree must not collide with subDirs + common trees.
    ## v2.4: enforces LayerPhase.DONE_PENDING at entry; transitions to DONE on success.
    ##   Phase contract: called after all three accumulation stages are complete.
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

    ## Guard: no .nix file and directory sharing the same base name in one directory.
    ## v2.4: minimal field destructuring — only `currentPath` and `suffix` are used.
    ##       `ctx` is returned unchanged on success (pipeline-composable).
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
        Resolution       : Layer pipeline stages must execute in the documented order:
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
    ## Rules:
    ##   • root basePath ("")            is omitted
    ##   • DirectoryRoot SourceKind      omits fileBase (the directory name IS the identity)
    ##   • variantName "default"         is omitted
    ##   • Empty result falls back       to "default"
    ##
    ## Examples (basePath="python", fileBase="renpy", variantName="default"):
    ##   NamedFile      → "python-renpy"
    ##   DirectoryRoot  → "python"         (fileBase omitted — file is default.nix)
    fn-makeFullName = basePath: sourceKind: fileBase: variantName:
      ([
        (if basePath    == fs.default-basePath             then null else basePath)
        (if sourceKind  == fs.SourceKind.DirectoryRoot     then null else fileBase)
        (if variantName == naming.default-variantName      then null else variantName)
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

    ## SourceKind enum — replaces AttrType for semantic clarity.
    ##
    ## v2.4: renamed from AttrType.{Default,Common} to SourceKind.{DirectoryRoot,NamedFile}
    ##   DirectoryRoot — file is default.nix; it represents the containing directory.
    ##                   The directory name is its identity; fileBase is omitted in naming.
    ##   NamedFile     — file is foo.nix; it is identified by its filename (fileBase).
    ##                   The filename contributes to the shell name.
    SourceKind = enum "SourceKind" [ "DirectoryRoot" "NamedFile" ];

    ## Parameter protocol for every imported attr file.
    ##
    ## Fields:
    ##   pkgs   — nixpkgs instance (mandatory, no default)
    ##   inputs — flake inputs (mandatory, no default — see v2.3 changelog)
    ##   shared — project shared config (mandatory, no default)
    ##   dev    — accumulated variantsTree visible to this file; scope depends on SourceKind:
    ##
    ## DevScope contract (what `dev` contains at import time):
    ## ┌─────────────────┬────────────────────────────────────────────────────┐
    ## │ SourceKind      │ dev contents                                       │
    ## ├─────────────────┼────────────────────────────────────────────────────┤
    ## │ NamedFile       │ { dirName: DirVariantsTree }                       │
    ## │                 │ Only sub-directory results are visible.            │
    ## │                 │ Common (.nix) files in the same directory are NOT  │
    ## │                 │ visible to each other (no cross-file dependencies).│
    ## ├─────────────────┼────────────────────────────────────────────────────┤
    ## │ DirectoryRoot   │ { dirName: DirVariantsTree }                       │
    ## │                 │   // { fileBase: FileVariantsTree }                │
    ## │                 │ Both sub-directory AND common file results are     │
    ## │                 │ visible. default.nix sees the complete picture.    │
    ## └─────────────────┴────────────────────────────────────────────────────┘
    ##
    ## This is an open record — shell files may use `{ pkgs, inputs, shared, dev, ... }`
    ## destructuring to remain forward-compatible with future extension fields.
    AttrFileParams = { pkgs, inputs, shared, dev ? {} } @ p: p;

    # ── Pure path predicates ────────────────────────────────────────────────
    fn-isPrivate   = name: lib.hasPrefix fs.default-private-prefix name;
    fn-isNixFile   = suffix: name: lib.hasSuffix suffix name;

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

    ## Read and validate attrs from a .nix file using the AttrFileParams protocol.
    ## `runtimeEnv'` carries pkgs/inputs/shared; `variantsTree` is the DevScope.
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
    ## v2.4: renamed from fn-flatShellsMapAttrs' for clarity.
    fn-buildFlatShells = basePath: sourceKind: fileBase: variantsTree:
      lib.mapAttrs' (variantName: attrsetCfg:
        (naming.fn-makeFullName basePath sourceKind fileBase variantName)
        |> (shellName: {
          name  = shellName;
          value = mkDevShell (attrsetCfg // { name = "dev-shell-${shellName}"; });
        })
      ) variantsTree;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §5  LAYER DATA STRUCTURES
  # ════════════════════════════════════════════════════════════════════════════

  layer = {

    ## CommonAttrs — flat accumulator for shells, variant tree, and name registry.
    ##
    ## variantsTree semantics per accumulator slot:
    ##   subDirsAttrs.variantsTree  : DirIndex    = { dirName:  LayerVariantsTree }
    ##   commonAttrs.variantsTree   : FileIndex   = { fileBase: FileVariantsTree  }
    ##   defaultAttrs.variantsTree  : RootVariants = { variantName: shellCfg      }
    ##
    ## All three use the same field name because they all represent "variant trees"
    ## at their respective level of the hierarchy.  The key type differs (dirName vs
    ## fileBase vs variantName), which is documented here and enforced by the strategies.
    CommonAttrs = { flatShells ? {}, variantsTree ? {}, shellNames ? [] }: {
      inherit flatShells variantsTree shellNames;
    };

    ## LayerContext — state machine envelope for processing one directory.
    ## Phases: SCAN → SUBDIRS → COMMON → DEFAULT → DONE
    ##
    ## v2.4: `phase` transitions are now enforced by validate.fn-assertLayerPhase.
    ##       `runtimeEnv` carries the DI root (pkgs/inputs/shared).
    Context = {
      currentPath,
      basePath,
      runtimeEnv,
      suffix        ? fs.default-nixSuffix,
      phase         ? LayerPhase.SCAN,
      subDirsAttrs  ? layer.CommonAttrs {},
      commonAttrs   ? layer.CommonAttrs {},
      defaultAttrs  ? layer.CommonAttrs {},
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
    ##
    ## `runtimeEnv` carries the DI root; `subVariantsTree` is the DevScope
    ## (what the imported file sees as `dev`).
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

      ## Strategy protocol — the interface every strategy must implement.
      FileStrategy = {
        sourceKind,              # SourceKind.DirectoryRoot | SourceKind.NamedFile
        targetField,             # LayerContext field to update ("commonAttrs" | "defaultAttrs")
        fn-getFileList,          # currentPath → suffix → [fileName]
        fn-getSubVariantsTree,   # LayerContext → variantsTree  (the DevScope for imported files)
        fn-aggregateVariantsTree,# [FileResult] → variantsTree
        fn-validationContext,    # currentPath → string (error message prefix)
      } @ p: p;

      ## NamedFileStrategy — processes all non-default .nix files.
      ##
      ## DevScope contract: `dev` = subDirsAttrs.variantsTree (DirIndex only).
      ## NamedFile (.nix) files see sub-directory results but NOT each other.
      ## This prevents circular cross-file dependencies within one directory.
      NamedFileStrategy = layer.FileProcessStrategy.FileStrategy {
        sourceKind            = fs.SourceKind.NamedFile;
        targetField           = "commonAttrs";
        fn-getFileList        = currentPath: currentSuffix:
          fs.fn-getAttrsFiles currentSuffix currentPath;
        fn-getSubVariantsTree = ctx: ctx.subDirsAttrs.variantsTree;
        fn-validationContext  = currentPath: "NAMED FILE ATTRS (${currentPath})";
        fn-aggregateVariantsTree = fileResults:
          ## FileIndex: { fileBase: FileVariantsTree }
          lib.listToAttrs (map (r: { name = r.fileBase; value = r.variantsTree; }) fileResults);
      };

      ## DirectoryRootStrategy — processes default.nix only.
      ##
      ## DevScope contract: `dev` = subDirsAttrs.variantsTree // commonAttrs.variantsTree.
      ## DirectoryRoot (default.nix) sees both sub-directory AND named-file results —
      ## it has the widest visibility and can compose variants from any source in the directory.
      DirectoryRootStrategy = layer.FileProcessStrategy.FileStrategy {
        sourceKind            = fs.SourceKind.DirectoryRoot;
        targetField           = "defaultAttrs";
        fn-getFileList        = currentPath: _currentSuffix:
          if fs.fn-hasDefaultAttrs currentPath then [ fs.default-nix ] else [];
        fn-getSubVariantsTree = ctx:
          ## DirIndex // FileIndex — full scope for default.nix
          ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree;
        fn-validationContext  = currentPath: "DIRECTORY ROOT ATTRS (${currentPath})";
        ## default.nix returns a flat variantsTree directly: { variantName: shellCfg }
        fn-aggregateVariantsTree = fileResults: (builtins.head fileResults).variantsTree;
      };

      ## Execute a strategy against the current LayerContext.
      ## Returns ctx unchanged when there are no files to process.
      ## Propagates `ctx.runtimeEnv` into every FileContext — no implicit captures.
      fn-execute = strategy: currentPath: basePath: ctx:
        (strategy.fn-getFileList currentPath ctx.suffix)
        |> (files:
          if files == []
          then ctx
          else (
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
          ));
    };

    ## Resolve the active strategies — use injected overrides when provided,
    ## fall back to the built-in implementations.
    activeStrategies = {
      namedFile      = if _commonStrategy  != null then _commonStrategy
                       else layer.FileProcessStrategy.NamedFileStrategy;
      directoryRoot  = if _defaultStrategy != null then _defaultStrategy
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
            flatShells   = lib.foldl' (acc: r: acc // r.flatShells)   {} layerResults;
            ## DirIndex: { dirName: LayerVariantsTree }
            variantsTree = lib.listToAttrs
              (map (r: { name = r.path; value = r.variantsTree; }) layerResults);
            shellNames   =
              (lib.concatMap (r: r.shellNames) layerResults)
              |> (validate.fn-assertUniqueNames "LAYER DIRECTORY ATTRS(${currentPath})");
          })
        |> (attrs: ctx // { phase = LayerPhase.SUBDIRS; subDirsAttrs = attrs; })
      );

    ## Stage 2/4: Process NamedFile (.nix) files — sees only subDirs variantsTree.
    ## v2.4: guarded by fn-assertLayerPhase SUBDIRS at entry (via FileStrategy.fn-execute
    ##       which receives ctx after phase is set to COMMON by this function).
    fn-processCommonAttrs = currentPath: basePath: ctx:
      validate.fn-assertLayerPhase LayerPhase.SUBDIRS ctx
      |> (ctx: ctx // { phase = LayerPhase.COMMON; })
      |> (layer.FileProcessStrategy.fn-execute
            layer.activeStrategies.namedFile currentPath basePath);

    ## Stage 3/4: Process DirectoryRoot (default.nix) — sees subDirs + common.
    fn-processDefaultAttrs = currentPath: basePath: ctx:
      validate.fn-assertLayerPhase LayerPhase.COMMON ctx
      |> (ctx: ctx // { phase = LayerPhase.DEFAULT; })
      |> (layer.FileProcessStrategy.fn-execute
            layer.activeStrategies.directoryRoot currentPath basePath);

    ## Full directory pipeline for one directory.
    ##
    ## v2.4: fn-assertFileExists is called INTERNALLY as the first step — hardening
    ##       the function so direct callers (e.g. tests) are also protected.
    ##       fn-processMain remains the canonical public entry point.
    ##
    ## Pipeline: validate path → bootstrap context → structural check →
    ##           SUBDIRS → COMMON → DEFAULT → conflict check (DONE) → LayerResult
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
            flatShells   = ctx.subDirsAttrs.flatShells   // ctx.commonAttrs.flatShells   // ctx.defaultAttrs.flatShells;
            variantsTree = ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree // ctx.defaultAttrs.variantsTree;
            ## v2.4: builtins.deepSeq forces strict evaluation of shellNames so the
            ## global uniqueness check always runs against a fully-realised list.
            shellNames   = builtins.deepSeq
              (ctx.subDirsAttrs.shellNames ++ ctx.commonAttrs.shellNames ++ ctx.defaultAttrs.shellNames)
              (ctx.subDirsAttrs.shellNames ++ ctx.commonAttrs.shellNames ++ ctx.defaultAttrs.shellNames);
          in layer.LayerResult { inherit path flatShells variantsTree shellNames; }
        )
      );

    ## Public entry point — validates path existence then delegates.
    ## fn-processDirectory also performs fn-assertFileExists internally (v2.4),
    ## so the check here is the outer guard with clear public-API semantics.
    fn-processMain = currentPath: basePath: path: currentSuffix: runtimeEnv':
      validate.fn-assertFileExists currentPath
      |> (validPath: layer.fn-processDirectory validPath basePath path currentSuffix runtimeEnv');
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
  ## v2.4: global uniqueness check converted from `assert` to pipeline-style lib.seq.
  ## lib.seq forces strict evaluation of the check before returning flatShells,
  ## consistent with the pipeline-dataflow principle throughout this module.
  rootResult.flatShells
  |> (shells:
    lib.seq
      (validate.fn-assertUniqueNames "GLOBAL NAMESPACE" rootResult.shellNames)
      shells)
