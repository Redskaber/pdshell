# @path: ~/projects/configs/nix-config/lib/dev/pdshells.nix
# @author: redskaber
# @version: 2.3.0
# @datetime: 2026-05-24
# @description: lib::dev::pdshells — Dataflow-driven layered shell loader
#
# == ARCHITECTURE PRINCIPLES ==
#  1. Dependency Inversion   — modules depend on protocol contracts, not implementations
#  2. Pipeline Dataflow      — |> left-to-right transforms; every stage returns a new Context
#  3. Layered Architecture   — recursive depth-first traversal with per-directory isolation
#  4. Incremental Mode       — variantsTree grows incrementally; shells registered as discovered
#  5. Strategy Management    — FileProcessStrategy is a first-class pluggable record
#  6. State Machine          — LayerContext transitions: SCAN → SUBDIRS → COMMON → DEFAULT → DONE
#  7. Lifecycle Management   — subDirs processed before common files before default.nix
#  8. Boundary Clarity       — public surface: pdshells output; internal: fs/layer/validate
#  9. Data-Driven            — behaviour driven by directory contents; no hard-coded names
# 10. Communication Protocol — LayerContext and LayerResult are typed envelopes
# 11. Plugin / Hot-swap      — combinFrom entries are composable plugins; strategies are swappable
#
# == CHANGELOG v2.3.0 ==
#  BUG FIX — Dependency Injection for `inputs` and `shared`
#
#  Root cause: `fs.fn-readFileAttrs` captured `shared` from the *module closure*
#  rather than threading it explicitly through the FileContext envelope.
#  Consequence: any call-site that constructs pdshells via `shared.pdshells { … }`
#  but whose `shared` value differs from the one visible at import-time would
#  silently receive a stale/empty attrset — causing `attribute 'unrpyc' missing`
#  and similar "attribute X missing on inputs" errors.
#
#  Fix strategy (Dependency Inversion + Communication Protocol):
#   • `RuntimeEnv` — a new explicit protocol record carrying { pkgs, inputs, shared }.
#     It is constructed ONCE at the top level and threaded through every layer/file
#     context without implicit closure capture.
#   • `FileContext`  gains `runtimeEnv` field; `fn-initialFileResult` reads from it.
#   • `fs.fn-readFileAttrs` receives `runtimeEnv` (not separate pkgs/inputs args)
#     so it can never silently fall back to a stale closure.
#   • `fs.AttrFileParams` default values for `inputs` and `shared` are REMOVED to
#     make missing propagation a hard evaluation error rather than a silent default.
#   • `layer.fn-processMain` accepts `runtimeEnv` and forwards it through the entire
#     pipeline — no stage invents its own copy.


{ pkgs, inputs, devDir, shared ? {}, suffix ? ".nix", ... }:
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
  #     This makes dependency injection explicit, testable, and hot-swappable.
  # ════════════════════════════════════════════════════════════════════════════

  RuntimeEnv = {
    ## Constructor / validator — ensures required fields are present.
    ## Extra fields are accepted (open record) to allow future extension.
    mk = { pkgs, inputs, shared, ... } @ env:
      if !lib.isAttrs env
        then throw "RuntimeEnv.mk: expected attrset, got ${builtins.typeOf env}"
      else if !lib.isAttrs inputs
        then throw "RuntimeEnv.mk: `inputs` must be an attrset (flake inputs), got ${builtins.typeOf inputs}"
      else if !lib.isAttrs shared
        then throw "RuntimeEnv.mk: `shared` must be an attrset, got ${builtins.typeOf shared}"
      else { inherit pkgs inputs shared; };
  };

  ## The single RuntimeEnv instance for this pdshells invocation.
  runtimeEnv = RuntimeEnv.mk { inherit pkgs inputs shared; };

  # ════════════════════════════════════════════════════════════════════════════
  # §1  VALIDATION MODULE
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

    ## Assert a filesystem path exists (fail-fast at loader entry).
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
    fn-assertDefaultAttrsConflicts = ctx:
      (ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree)
      |> (variantsTree:
          validate.fn-assertNoKeyConflicts
            "VARIANTS TREE"
            variantsTree
            ctx.defaultAttrs.variantsTree
            ctx);

    ## Guard: no .nix file and directory sharing the same base name in one directory.
    ## Also catches empty directories.  Returns ctx on success.
    fn-assertStructuralValidation = ctx:
      (fs.fn-listDir ctx.currentPath)
      |> (entries: {
          nixFiles = lib.filter (fs.fn-isAttrsFile ctx.currentPath) entries;
          subDirs  = lib.filter (fs.fn-isAttrsDir  ctx.currentPath) entries;
        })
      |> (items:
          if items.nixFiles == [] && items.subDirs == []
          then throw "EMPTY DIRECTORY: ${ctx.currentPath} requires .nix files or sub-dirs"
          else items)
      |> (items:
          (map (fn: fs.fn-makeFileBase ctx.suffix fn) items.nixFiles)
          |> (fileBases: lib.filter (n: lib.elem n items.subDirs) fileBases))
      |> (conflicts:
          if conflicts != []
          then throw ''
            STRUCTURAL AMBIGUITY in ${ctx.currentPath}:
            • Conflicting sources: ${builtins.concatStringsSep ", " conflicts}
            Resolution: ONE source per base name — EITHER file OR directory, NOT both.
            ${builtins.concatStringsSep " AND "
                (map (n: "${n}${ctx.suffix} vs ${n}/") conflicts)}
          ''
          else ctx);
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §2  NAMING MODULE
  # ════════════════════════════════════════════════════════════════════════════

  naming = {
    default-variantName = "default";
    default-concat-sep  = "-";

    ## Derive the canonical shell name from hierarchy position.
    ## Rules:
    ##   • root basePath ("")       is omitted
    ##   • Default AttrType         omits fileBase (directory name is the identity)
    ##   • variantName "default"    is omitted
    ##   • Empty result falls back  to "default"
    fn-makeFullName = basePath: attrType: fileBase: variantName:
      ([
        (if basePath    == fs.default-basePath         then null else basePath)
        (if attrType    == fs.AttrType.Default         then null else fileBase)
        (if variantName == naming.default-variantName  then null else variantName)
      ]
      |> lib.filter (x: x != null))
      |> lib.concatStringsSep naming.default-concat-sep
      |> (fullName: if fullName == "" then naming.default-variantName else fullName);
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §3  FILESYSTEM MODULE
  # ════════════════════════════════════════════════════════════════════════════

  fs = {
    default-nix            = "default.nix";
    default-path           = "dev";
    default-basePath       = "";
    default-fileBase       = "";
    default-private-prefix = "_";
    default-nixSuffix      = ".nix";

    ## AttrType enum — contract-based, no bare strings.
    AttrType = enum "AttrType" [ "Default" "Common" ];

    ## Parameter protocol for every imported attr file.
    ##
    ## BREAKING CHANGE from v2.2: `inputs` and `shared` no longer have
    ## default values.  They must be supplied explicitly — the absence of
    ## a default surfaces propagation bugs as hard evaluation errors rather
    ## than silent empty-attrset substitutions.
    ##
    ## The record is open (`@ p: p`) to remain forward-compatible with
    ## future extension fields without breaking existing shell files that
    ## use `{ pkgs, inputs, shared, ... }` destructuring.
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
    ##
    ## v2.3: receives `runtimeEnv` (not separate pkgs/inputs args) — explicit DI.
    ## `dev` is the accumulated variantsTree visible to this file at import time.
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
    fn-flatShellsMapAttrs' = basePath: attrType: fileBase: variantsTree:
      lib.mapAttrs' (variantName: attrsetCfg:
        (naming.fn-makeFullName basePath attrType fileBase variantName)
        |> (shellName: {
          name  = shellName;
          value = mkDevShell (attrsetCfg // { name = "dev-shell-${shellName}"; });
        })
      ) variantsTree;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §4  LAYER DATA STRUCTURES
  # ════════════════════════════════════════════════════════════════════════════

  layer = {

    ## CommonAttrs — flat accumulator for shells, variant tree, and name registry.
    CommonAttrs = { flatShells ? {}, variantsTree ? {}, shellNames ? [] }: {
      inherit flatShells variantsTree shellNames;
    };

    ## LayerContext — state machine envelope for processing one directory.
    ## Phases: SCAN → SUBDIRS → COMMON → DEFAULT → DONE
    ##
    ## v2.3: `runtimeEnv` field added — carries the DI root through every stage.
    Context = {
      currentPath,
      basePath,
      runtimeEnv,
      suffix        ? fs.default-nixSuffix,
      phase         ? "SCAN",
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
    ## v2.3: `inputs` and `pkgs` fields REMOVED in favour of `runtimeEnv`.
    ##   Rationale: keeping them as separate fields caused accidental shadowing
    ##   and made it possible to pass inconsistent pkgs/inputs combinations.
    ##   A single `runtimeEnv` field makes the dependency boundary unambiguous.
    FileContext = {
      currentPath,
      basePath,
      attrType,
      fileName,
      subVariantsTree,
      runtimeEnv,
      suffix  ? fs.default-nixSuffix,
    }: {
      inherit currentPath basePath attrType fileName subVariantsTree runtimeEnv suffix;
    };

    ## Process one .nix file: read → flatten → register.
    ##
    ## v2.3: reads pkgs from `fileCtx.runtimeEnv` — no implicit closure capture.
    fn-initialFileResult = fileCtx:
      let
        fileBase     = fs.fn-makeFileBase fileCtx.suffix fileCtx.fileName;
        filePath     = "${fileCtx.currentPath}/${fileCtx.fileName}";
        variantsTree = fs.fn-readFileAttrs filePath fileCtx.runtimeEnv fileCtx.subVariantsTree;
        flatShells   = fs.fn-flatShellsMapAttrs'
                         fileCtx.basePath fileCtx.attrType fileBase variantsTree;
        shellNames   = builtins.attrNames flatShells;
      in layer.FileResult { inherit fileBase flatShells variantsTree shellNames; };

    # ── FILE PROCESS STRATEGY  (plugin pattern) ──────────────────────────────
    # Each strategy is a first-class record describing HOW to process a file category.

    FileProcessStrategy = {

      ## Strategy protocol (contract / interface definition).
      FileStrategy = {
        attrType,
        targetField,
        fn-getFileList,
        fn-getSubVariantsTree,
        fn-aggregateVariantsTree,
        fn-validationContext,
      } @ p: p;

      ## Common strategy: all non-default .nix files; sees only subDirs variantsTree.
      CommonStrategy = layer.FileProcessStrategy.FileStrategy {
        attrType              = fs.AttrType.Common;
        targetField           = "commonAttrs";
        fn-getFileList        = currentPath: currentSuffix: fs.fn-getAttrsFiles currentSuffix currentPath;
        fn-getSubVariantsTree = ctx: ctx.subDirsAttrs.variantsTree;
        fn-validationContext  = currentPath: "COMMON ATTRS FILES(${currentPath})";
        fn-aggregateVariantsTree = fileResults:
          lib.listToAttrs (map (r: { name = r.fileBase; value = r.variantsTree; }) fileResults);
      };

      ## Default strategy: default.nix only; sees subDirs + common variantsTrees.
      DefaultStrategy = layer.FileProcessStrategy.FileStrategy {
        attrType              = fs.AttrType.Default;
        targetField           = "defaultAttrs";
        fn-getFileList        = currentPath: _currentSuffix:
          if fs.fn-hasDefaultAttrs currentPath then [ fs.default-nix ] else [];
        fn-getSubVariantsTree = ctx:
          ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree;
        fn-validationContext  = currentPath: "DEFAULT ATTRS FILE(${currentPath})";
        fn-aggregateVariantsTree = fileResults: (builtins.head fileResults).variantsTree;
      };

      ## Execute a strategy against the current LayerContext.
      ## Returns ctx unchanged when there are no files to process.
      ##
      ## v2.3: propagates `ctx.runtimeEnv` into every FileContext — no implicit captures.
      fn-execute = strategy: currentPath: basePath: ctx:
        (strategy.fn-getFileList currentPath ctx.suffix)
        |> (files:
          if files == []
          then ctx
          else (
            map (fileName: layer.fn-initialFileResult (layer.FileContext {
              inherit currentPath basePath fileName;
              attrType        = strategy.attrType;
              suffix          = ctx.suffix;
              runtimeEnv      = ctx.runtimeEnv;               # ← explicit DI
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

    # ── LAYER PIPELINE STAGES ─────────────────────────────────────────────────

    ## Stage 1/4: Recursively process sub-directories (depth-first).
    ##
    ## v2.3: passes `runtimeEnv` from ctx into every recursive call explicitly.
    fn-processSubDirs = currentPath: basePath: ctx:
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
          variantsTree = lib.listToAttrs
            (map (r: { name = r.path; value = r.variantsTree; }) layerResults);
          shellNames   =
            (lib.concatMap (r: r.shellNames) layerResults)
            |> (validate.fn-assertUniqueNames "LAYER DIRECTORY ATTRS(${currentPath})");
        })
      |> (attrs: ctx // { phase = "SUBDIRS"; subDirsAttrs = attrs; });

    ## Stage 2/4: Process common .nix files.
    fn-processCommonAttrs = currentPath: basePath: ctx:
      layer.FileProcessStrategy.fn-execute
        layer.FileProcessStrategy.CommonStrategy currentPath basePath
        (ctx // { phase = "COMMON"; });

    ## Stage 3/4: Process default.nix.
    fn-processDefaultAttrs = currentPath: basePath: ctx:
      layer.FileProcessStrategy.fn-execute
        layer.FileProcessStrategy.DefaultStrategy currentPath basePath
        (ctx // { phase = "DEFAULT"; });

    ## Full directory pipeline.
    ##
    ## v2.3: `runtimeEnv'` is now an explicit parameter — no closure capture.
    fn-processDirectory = currentPath: basePath: path: currentSuffix: runtimeEnv':
      (layer.fn-initialContext currentPath basePath currentSuffix runtimeEnv')
      |> validate.fn-assertStructuralValidation
      |> (layer.fn-processSubDirs     currentPath basePath)
      |> (layer.fn-processCommonAttrs currentPath basePath)
      |> (layer.fn-processDefaultAttrs currentPath basePath)
      |> validate.fn-assertDefaultAttrsConflicts
      |> (ctx: ctx // { phase = "DONE"; })
      |> (ctx: layer.LayerResult {
          path         = path;
          flatShells   = ctx.subDirsAttrs.flatShells   // ctx.commonAttrs.flatShells   // ctx.defaultAttrs.flatShells;
          variantsTree = ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree // ctx.defaultAttrs.variantsTree;
          shellNames   = ctx.subDirsAttrs.shellNames   ++ ctx.commonAttrs.shellNames   ++ ctx.defaultAttrs.shellNames;
        });

    ## Entry-point: validate path existence then delegate to fn-processDirectory.
    ##
    ## v2.3: `runtimeEnv'` threaded through — single DI root.
    fn-processMain = currentPath: basePath: path: currentSuffix: runtimeEnv':
      (validate.fn-assertFileExists currentPath)
      |> (validPath: layer.fn-processDirectory validPath basePath path currentSuffix runtimeEnv');
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §5  TOP-LEVEL EXECUTION
  # ════════════════════════════════════════════════════════════════════════════

  rootResult = layer.fn-processMain
    devDir
    fs.default-basePath
    fs.default-path
    suffix
    runtimeEnv;          # ← the single RuntimeEnv instance, assembled at §0

  _global_unique_check =
    lib.seq
      (validate.fn-assertUniqueNames "GLOBAL NAMESPACE" rootResult.shellNames)
      true;

in
  assert _global_unique_check;
  rootResult.flatShells
