# @path: ~/projects/configs/nix-config/lib/dev/pdshells.nix
# @author: redskaber
# @version: 2.2.0
# @datetime: 2026-05-14
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


{ pkgs, inputs, devDir, shared ? {}, suffix ? ".nix", ... }:
let
  lib = pkgs.lib;
  inherit (inputs.nix-types.enum) enum;
  inherit (import ./mk-pdshell.nix { inherit pkgs; }) mkDevShell;

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
    default-nixSuffix      = ".nix";    # canonical suffix; module param `suffix` overrides at runtime

    ## AttrType enum — contract-based, no bare strings.
    AttrType = enum "AttrType" [ "Default" "Common" ];

    ## Parameter protocol for every imported attr file.
    AttrFileParams = { pkgs, inputs ? {}, shared ? {}, dev ? {} } @ p: p;

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
    fn-readFileAttrs = filePath: pkgs': inputs': variantsTree:
      (fs.AttrFileParams { pkgs = pkgs'; inputs = inputs'; inherit shared; dev = variantsTree; })
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
    Context = {
      currentPath,
      basePath,
      suffix        ? fs.default-nixSuffix,
      phase         ? "SCAN",
      subDirsAttrs  ? layer.CommonAttrs {},
      commonAttrs   ? layer.CommonAttrs {},
      defaultAttrs  ? layer.CommonAttrs {},
    }: {
      inherit currentPath basePath suffix phase
              subDirsAttrs commonAttrs defaultAttrs;
    };

    ## Bootstrap a fresh LayerContext for a directory.
    fn-initialContext = currentPath: basePath: currentSuffix:
      layer.Context { inherit currentPath basePath; suffix = currentSuffix; };

    ## LayerResult — final typed output for one directory.
    LayerResult = { path, flatShells, variantsTree, shellNames } @ p: p;

    ## FileResult — output of processing one .nix file.
    FileResult = { fileBase, flatShells, variantsTree, shellNames } @ p: p;

    ## FileContext — input contract for processing a single .nix file.
    FileContext = {
      currentPath,
      basePath,
      attrType,
      fileName,
      subVariantsTree,
      inputs,
      suffix  ? fs.default-nixSuffix,
      pkgs    ? pkgs,
    }: {
      inherit currentPath basePath attrType fileName subVariantsTree inputs suffix pkgs;
    };

    ## Process one .nix file: read → flatten → register.
    fn-initialFileResult = fileCtx:
      let
        fileBase     = fs.fn-makeFileBase fileCtx.suffix fileCtx.fileName;
        filePath     = "${fileCtx.currentPath}/${fileCtx.fileName}";
        variantsTree = fs.fn-readFileAttrs filePath fileCtx.pkgs fileCtx.inputs fileCtx.subVariantsTree;
        flatShells   = fs.fn-flatShellsMapAttrs' fileCtx.basePath fileCtx.attrType fileBase variantsTree;
        shellNames   = builtins.attrNames flatShells;
      in layer.FileResult { inherit fileBase flatShells variantsTree shellNames; };

    # ── FILE PROCESS STRATEGY  (plugin pattern) ──────────────────────────────
    # Each strategy is a first-class record describing HOW to process a file category.
    # New strategies can be added without modifying the core pipeline.

    FileProcessStrategy = {

      ## Strategy protocol (contract / interface definition).
      FileStrategy = {
        attrType,                  # AttrType.Default | AttrType.Common
        targetField,               # LayerContext field to update
        fn-getFileList,            # currentPath → suffix → [ fileName ]
        fn-getSubVariantsTree,     # LayerContext → variantsTree (visible to the imported file)
        fn-aggregateVariantsTree,  # [FileResult] → variantsTree
        fn-validationContext,      # currentPath → string (error message prefix)
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
      fn-execute = strategy: currentPath: basePath: ctx:
        (strategy.fn-getFileList currentPath ctx.suffix)
        |> (files:
          if files == []
          then ctx
          else (
            map (fileName: layer.fn-initialFileResult (layer.FileContext {
              inherit currentPath basePath pkgs inputs fileName;
              attrType        = strategy.attrType;
              suffix          = ctx.suffix;
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
    # Processing order per directory:
    #   SUBDIRS (depth-first recursive) → COMMON files → DEFAULT file → DONE

    ## Stage 1/4: Recursively process sub-directories (depth-first).
    fn-processSubDirs = currentPath: basePath: ctx:
      (fs.fn-getAttrsDirs currentPath)
      |> (dirPaths: map (path:
            let
              newBase = if basePath == fs.default-basePath
                        then path
                        else "${basePath}-${path}";
            in layer.fn-processDirectory
                 "${currentPath}/${path}" newBase path ctx.suffix
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

    ## Stage 2/4: Process common .nix files (see only subDirs variantsTree).
    fn-processCommonAttrs = currentPath: basePath: ctx:
      layer.FileProcessStrategy.fn-execute
        layer.FileProcessStrategy.CommonStrategy currentPath basePath
        (ctx // { phase = "COMMON"; });

    ## Stage 3/4: Process default.nix (sees subDirs + common variantsTrees).
    fn-processDefaultAttrs = currentPath: basePath: ctx:
      layer.FileProcessStrategy.fn-execute
        layer.FileProcessStrategy.DefaultStrategy currentPath basePath
        (ctx // { phase = "DEFAULT"; });

    ## Full directory pipeline:
    ##   bootstrap → validate → SUBDIRS → COMMON → DEFAULT → conflict check → DONE → LayerResult
    ## Takes explicit (currentPath, basePath, path, suffix) — no ctx parameter.
    ## Each directory gets a fresh LayerContext for full isolation.
    fn-processDirectory = currentPath: basePath: path: currentSuffix:
      (layer.fn-initialContext currentPath basePath currentSuffix)
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
    ## validPath (the return value of fn-assertFileExists) is forwarded — not discarded.
    fn-processMain = currentPath: basePath: path: currentSuffix:
      (validate.fn-assertFileExists currentPath)
      |> (validPath: layer.fn-processDirectory validPath basePath path currentSuffix);
  };

  # ════════════════════════════════════════════════════════════════════════════
  # §5  TOP-LEVEL EXECUTION
  # ════════════════════════════════════════════════════════════════════════════

  rootResult = layer.fn-processMain devDir fs.default-basePath fs.default-path suffix;

  ## Global uniqueness guard: lib.seq forces strict evaluation so the check
  ## always runs (never left as a lazy thunk that might be silently skipped).
  _global_unique_check =
    lib.seq
      (validate.fn-assertUniqueNames "GLOBAL NAMESPACE" rootResult.shellNames)
      true;

in
  # Public surface: flat { shellName = derivation; ... }
  # _global_unique_check is referenced via assert to prevent dead-code elimination.
  assert _global_unique_check;
  rootResult.flatShells
