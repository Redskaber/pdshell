# @path: ～/projects/configs/nix-config/lib/dev/pdshells.nix
# @author: redskaber
# @datetime: 2026-02-02
# @description: lib::dev::pdshells - Dataflow-driven layered loader with pipeline architecture
# - Pipeline and Dataflow and Currying and Strategy and Recursive

{ pkgs, inputs, devDir, shared ? {}, suffix ? ".nix", ... }:
let
  inherit (inputs.nix-types.enum) enum;
  inherit (import ./mk-pdshell.nix { inherit pkgs; }) mkDevShell;

  # == VALIDATION MODULE (pipeline-optimized) ==
  validate = {
    # Pipeline-friendly validation primitives (curried)

    # @context: string
    # @value: any
    fn-assertAttrSet = context: value:
      if pkgs.lib.isAttrs value then value else throw ''
        INVALID STRUCTURE (${context}):
        • Expected: attrset
        • Got: ${builtins.typeOf value}
        Resolution: Ensure file returns an attrset like:
          { default = { buildInputs = [ ... ]; }; }
      '';

    # @context: string
    # @names: [ string ]
    fn-assertUniqueNames = context: names:
      (builtins.groupBy (x: x) names) # O(n)
      |> (groups: pkgs.lib.filterAttrs (_: g: builtins.length g > 1) groups)  # O(m)
      |> (dupGroups: builtins.attrNames dupGroups)
      |> (dupNames: if dupNames == [] then names else throw ''
          ${context} NAMING CONFLICT:
          • Duplicate identifiers: ${builtins.concatStringsSep ", " dupNames}
          Resolution: Follow naming protocol:
            - default.nix variant 'X' → [base]-X
            - X.nix variant 'default' → [base]-X (AVOID if [base]-X exists)
          Fix by renaming variants/files for global uniqueness.
        '');

    # @path: string
    fn-assertFileExists = path:
      if builtins.pathExists path then path else throw ''
        PATH NOT FOUND: ${path}
        Resolution: Verify directory structure matches expectations.
      '';

    # Pipeline checker for pipeline build variantsTree
    # @context: string
    # @base: {...}
    # @new: {...}
    # @ctx: Context
    fn-assertNoKeyConflicts = context: base: new: ctx:
      (builtins.attrNames new)
      |> (newKeys: pkgs.lib.filter (key: pkgs.lib.hasAttr key base) newKeys)
      |> (conflicts: if conflicts == [] then ctx else throw ''
          ${context} KEY COLLISION:
          • Conflicting keys: ${builtins.concatStringsSep ", " conflicts}
          • Base keys: ${builtins.concatStringsSep ", " (builtins.attrNames base)}
          • New keys: ${builtins.concatStringsSep ", " (builtins.attrNames new)}
          Resolution: Rename variants in default.nix or conflicting files/dirs.
        '');

    # Prevent key collisions in variants tree
    # @ctx: Context
    fn-assertDefaultAttrsConflicts = ctx:
      (ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree)
      |> (variantsTree: validate.fn-assertNoKeyConflicts "VARIANTS TREE" variantsTree ctx.defaultAttrs.variantsTree ctx);

    # Structural validation pipeline
    # @ctx: Context
    fn-assertStructuralValidation = ctx:
      (fs.fn-listDir ctx.currentPath)
      |> (entries: {
          nixFiles = pkgs.lib.filter (fs.fn-isAttrsFile ctx.currentPath) entries;
          subDirs = pkgs.lib.filter (fs.fn-isAttrsDir ctx.currentPath) entries;
        })
      |> (items: if items.nixFiles == [] && items.subDirs == []
          then throw "EMPTY DIRECTORY: ${ctx.currentPath} requires attrs .nix files or sub dirs"
          else items
        )
      |> (items: (map (fileName: fs.fn-makeFileBase ctx.suffix fileName) items.nixFiles)
          |> (fileBases: pkgs.lib.filter (n: pkgs.lib.elem n items.subDirs) fileBases)
        )
      |> (conflicts : if conflicts  != [] then throw ''
          STRUCTURAL AMBIGUITY in ${ctx.currentPath}:
          • Conflicting sources: ${builtins.concatStringsSep ", " conflicts}
          Resolution: Maintain ONE source per base name:
            - EITHER file (${ctx.suffix}) OR directory
            - NOT both ${builtins.concatStringsSep " AND " (map (name: "${name}${ctx.suffix} vs ${name}/") conflicts)}
          '' else ctx);
  };

  # == CORE ARCHITECTURE PATTERNS ==
  # 1. Pipeline composition: |> for data transformation
  # 2. Layer isolation: pure functions with explicit context
  # 3. Early validation: fail-fast at source
  # 4. Semantic naming: decoupled naming strategy

  # == NAMING STRATEGY MODULE ==
  naming = {
    default-variantName = "default";
    default-concat-sep = "-";
    # Unified naming pipeline with pipe operators
    # @basePath: string
    # @attrType: enum::AttrType
    # @fileBase: string
    # @variantName: string
    fn-makeFullName = basePath: attrType: fileBase: variantName:
      ([
        (if basePath == fs.default-basePath then null else basePath)
        (if attrType == fs.AttrType.Default then null else fileBase)
        (if variantName == naming.default-variantName then null else variantName)
      ]
      |> pkgs.lib.filter (x: x != null))                      # Remove empty parts
      |> pkgs.lib.concatStringsSep naming.default-concat-sep  # Join with hyphens
      |> (fullName: if fullName == "" then naming.default-variantName else fullName); # Handle empty case
  };

  # == FILESYSTEM MODULE (pure path operations) ==
  fs = {
    default-nix = "default.nix";
    default-path = "dev";
    default-basePath = "";
    default-fileBase = "";
    default-private-prefix = "_";
    default-nixSuffix = ".nix";
    # Since Nix lacks native support for data structures,
    # we utilize native datasets and employ a contract-based approach to simulate enums,
    # aiming for clearer semantic expression.
    AttrType = enum "AttrType" [
      "Default"
      "Common"
    ];

    # AttrFile Params Protocol
    AttrFileParams = {
      pkgs,
      inputs ? {},
      shared ? {},
      dev ? {},
    } @devParams: devParams;

    # Curried type checkers (pipeline-ready)
    fn-isPrivate = name: (pkgs.lib.hasPrefix fs.default-private-prefix name);
    fn-isNixFile = name: (pkgs.lib.hasSuffix fs.default-nixSuffix name);

    fn-isType = expectedType: path: name:
      (builtins.readDir path).${name}
      |> (type: type == expectedType);

    fn-isRegular = fs.fn-isType "regular";
    fn-isDirectory = fs.fn-isType "directory";
    fn-isAttrsDir = path: name:
      (fs.fn-isDirectory path name)
      && !fs.fn-isPrivate name;
    fn-isAttrsFile = path: name:
      (fs.fn-isRegular path name)
      && fs.fn-isNixFile name
      && !fs.fn-isPrivate name;

    fn-listDir = path:
      builtins.readDir path
      |> builtins.attrNames;

    # High-level directory scanners (optimized pipelines)
    fn-getAttrsDirs = path:
      (fs.fn-listDir path)
      |> (entries: pkgs.lib.filter (name: fs.fn-isAttrsDir path name) entries);
    fn-getAttrsFiles = path:
      (fs.fn-listDir path)
      |> (entries: pkgs.lib.filter (name: name != fs.default-nix && fs.fn-isAttrsFile path name) entries);

    fn-hasDefaultAttrs = path:
      (fs.fn-listDir path)
      |> (entries: pkgs.lib.any (name: name == fs.default-nix) entries);

    # Single file attrs mapAttrs' and flat shells
    # @basePath: string
    # @attrType: AttrType
    # @fileBase: string
    # @variantsTree: { ... }
    fn-flatShellsMapAttrs' = basePth: attrType: fileBase: variantsTree:
      pkgs.lib.mapAttrs' (variantName: attrsetCfg:
        (naming.fn-makeFullName basePth attrType fileBase variantName)
        |> (name: {
          name = name;
          value = mkDevShell (attrsetCfg // { name = "dev-shell-${name}"; });
        })
      ) variantsTree;

    # Get file base
    # @suffix: string
    # @fileName: string
    fn-makeFileBase = suffix: fileName:
      pkgs.lib.removeSuffix suffix fileName;

    # Read file attrsets
    fn-readFileAttrs = filePath: pkgs: inputs: variantsTree:
      (fs.AttrFileParams { inherit pkgs inputs shared; dev = variantsTree; })
      |> (attrFileParams: import filePath attrFileParams )
      |> (vars: validate.fn-assertAttrSet "FILE CONTENT (${filePath})" vars);
  };


  # == LAYER PROCESSING MODULE ==
  layer = {
    # Since Nix lacks native support for data structures,
    # we simulate structs using its native function capabilities
    # to achieve a visual representation of the internal data.

    # Common layer attrs schema
    # @flatShells:   { shellName<string> : Shell<derivation>, ... }
    # @variantsTree: { sublayer::variantsTree<string, attrset>, commonAttrsets<string, attrset>, defaultAttrsets<string, attrset> }
    # @shellNames:   { shellNames<string>, ... }
    CommonAttrs = {
      flatShells ? {},
      variantsTree ? {},
      shellNames ? [],
    }: {
      flatShells = flatShells;
      variantsTree = variantsTree;
      shellNames = shellNames;
    };

   # Context attrs schema
    Context = {
      currentPath,
      basePath,
      suffix ? fs.default-nixSuffix,
      subDirsAttrs ? layer.CommonAttrs {},
      commonAttrs ? layer.CommonAttrs {},
      defaultAttrs ? layer.CommonAttrs {},
    }: {
      currentPath = currentPath;
      basePath = basePath;
      suffix = suffix;
      subDirsAttrs = subDirsAttrs;
      commonAttrs = commonAttrs;
      defaultAttrs = defaultAttrs;
    };

    # Initial Context Function Callable
    # @currentPath: string
    # @basePath: string
    # @suffix: string
    fn-initialContext = currentPath: basePath: suffix:
      (layer.Context { currentPath=currentPath; basePath=basePath; suffix=suffix; });

    # Layer result data schema
    # @path: string
    # @flatShells:   { shellName<string> : Shell<derivation> }
    # @variantsTree: { sublayer::variantsTree<string, attrset>, commonAttrsets<string, attrset>, defaultAttrsets<string, attrset> }
    # @shellNames:   { shellNames<string> }
    LayerResult = {
      path,
      flatShells,
      variantsTree,
      shellNames,
    } @params: params;

    #Initial LayerResult Function Callable
    # @currentPath: string (current full path)
    # @basePath: string
    # @path: string (current active path)
    fn-initialLayerResult = currentPath: basePath: path: ctx:
      (if basePath == fs.default-basePath then path else "${basePath}-${path}")
      |>(newBasePath: layer.fn-processDirectory "${currentPath}/${path}" newBasePath path ctx);

    # File result date schema
    # @fileBase: string
    # @flatShells:   { shellName<string> : Shell<derivation>, ... }
    # @variantsTree: { sublayer::variantsTree<string, attrset>, commonAttrsets<string, attrset>, defaultAttrsets<string, attrset> }
    # @shellNames:   { shellNames<string>, ... }
    FileResult = {
      fileBase,
      flatShells,
      variantsTree,
      shellNames,
    } @params: params;

    # File constract schema
    # @currentPath: string
    # @basePath: string
    # @attrType: AttrType
    # @fileName: string
    # @subVariantsTree: variantsTree
    # @inputs: { ... }
    # @suffix: string
    # @pkgs: nixpkgs
    FileContext = {
      currentPath,
      basePath,
      attrType,
      fileName,
      subVariantsTree,
      inputs,
      suffix ? fs.default-nixSuffix,
      pkgs ? import <nixpkgs> {},
    }: {
      currentPath = currentPath;
      basePath = basePath;
      attrType = attrType;
      fileName = fileName;
      subVariantsTree = subVariantsTree;
      inputs = inputs;
      suffix = suffix;
      pkgs = pkgs;
    };

    # Initial FileResult Function Callsble
    # @fileCtx: FileContext
    # @return: FileResult
    fn-initialFileResult = fileCtx:
      let
        fileBase = fs.fn-makeFileBase fileCtx.suffix fileCtx.fileName;
        filePath = "${fileCtx.currentPath}/${fileCtx.fileName}";
        variantsTree = fs.fn-readFileAttrs filePath fileCtx.pkgs fileCtx.inputs fileCtx.subVariantsTree;
        flatShells = fs.fn-flatShellsMapAttrs' fileCtx.basePath fileCtx.attrType fileBase variantsTree;
        shellNames = builtins.attrNames flatShells;
      in layer.FileResult {
        fileBase = fileBase;  # Used common attrs files mapping'
        flatShells = flatShells;
        variantsTree = variantsTree;
        shellNames = shellNames;
      };

    FileProcessStrategy = {
      # File handle strategy protocol
      # @attrType: AttrType
      # @targetField: string
      # @fn-getFileList: |string, string| -> [ string ]
      # @fn-getSubVariantsTree: |Context| -> variantsTree
      # @fn-aggregateVariantsTree: |[FileResult]| -> attrset { ... }
      # @fn-validationContext: |string| -> string
      FileStrategy = {
        attrType,
        targetField,
        fn-getFileList,
        fn-getSubVariantsTree,
        fn-aggregateVariantsTree,
        fn-validationContext,
      } @params: params;

      CommonStrategy = layer.FileProcessStrategy.FileStrategy {
        attrType = fs.AttrType.Common;
        targetField = "commonAttrs";
        fn-getFileList = currentPath: fs.fn-getAttrsFiles currentPath;
        fn-getSubVariantsTree = ctx: ctx.subDirsAttrs.variantsTree;
        fn-validationContext = currentPath: "COMMON ATTRS FILES(${currentPath})";
        fn-aggregateVariantsTree = fileResults: pkgs.lib.listToAttrs (map (r: { name = r.fileBase; value = r.variantsTree; }) fileResults);
      };

      DefaultStrategy = layer.FileProcessStrategy.FileStrategy {
        attrType = fs.AttrType.Default;
        targetField = "defaultAttrs";
        fn-getFileList = currentPath: if fs.fn-hasDefaultAttrs currentPath then [ fs.default-nix ] else [];
        fn-getSubVariantsTree = ctx: ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree;
        fn-validationContext = currentPath: "DEFAULT ATTRS FILE(${currentPath})";
        fn-aggregateVariantsTree = fileResults: (builtins.head fileResults).variantsTree;
      };

      fn-execute = strategy: currentPath: basePath: ctx:
        (strategy.fn-getFileList currentPath)
        |>(files: if files == []
          then ctx
          else (
            map (fileName: layer.fn-initialFileResult (layer.FileContext {
                inherit currentPath basePath pkgs inputs fileName;
                attrType = strategy.attrType;
                suffix = ctx.suffix;
                subVariantsTree = strategy.fn-getSubVariantsTree ctx;
            })) files
            |> (fileResults: layer.CommonAttrs {
              variantsTree = (strategy.fn-aggregateVariantsTree fileResults);
              flatShells   = (pkgs.lib.foldl' (acc: r: acc // r.flatShells) {} fileResults);
              shellNames   = (pkgs.lib.concatMap (r: r.shellNames) fileResults)
                |> (names: validate.fn-assertUniqueNames (strategy.fn-validationContext currentPath)  names);
            })
            |> (attrs: ctx // { ${strategy.targetField} = attrs; })
          )
        );
    };

    # Process subdir dectories FIRST (depth-first)
    # @currentPath: string
    # @basePath: string
    # @ctx: Context
    fn-processLayerAttrs = currentPath: basePath: ctx:
      (fs.fn-getAttrsDirs currentPath)
      |> (dirPaths: map (path: layer.fn-initialLayerResult currentPath basePath path ctx) dirPaths)
      |> (layerResults: layer.CommonAttrs {
          flatShells = pkgs.lib.foldl' (acc: r: acc // r.flatShells) {} layerResults;
          variantsTree = pkgs.lib.listToAttrs (map (r: { name = r.path; value = r.variantsTree; }) layerResults);
          shellNames = (pkgs.lib.concatMap (r: r.shellNames) layerResults)
            |> (names: validate.fn-assertUniqueNames "LAYER DIRECTORY ATTRS(${currentPath})" names);
        })
      |> (attrs: ctx // { subDirsAttrs = attrs; });

    # Process non-default files (common attrs files, isolated context: sees ONLY subdirs)
    # @currentPath: string
    # @basePath: string
    # @ctx: Context
    fn-processCommonAttrs = currentPath: basePath: ctx:
      layer.FileProcessStrategy.fn-execute
        layer.FileProcessStrategy.CommonStrategy currentPath basePath ctx;

    # Process default.nix LAST (default attrs file, full context: subdirs + non-default files)
    # @currentPath: string
    # @basePath: string
    # @ctx: Context
    fn-processDefaultAttrs = currentPath: basePath: ctx:
      layer.FileProcessStrategy.fn-execute
        layer.FileProcessStrategy.DefaultStrategy currentPath basePath ctx;

    # Directory processor (pipeline architecture)
    # @currentPath: string
    # @basePath: string
    fn-processDirectory = currentPath: basePath: path: ctx:
      ctx
      |> (ctx: validate.fn-assertStructuralValidation ctx)
      |> (ctx: layer.fn-processLayerAttrs currentPath basePath ctx)
      |> (ctx: layer.fn-processCommonAttrs currentPath basePath ctx)
      |> (ctx: layer.fn-processDefaultAttrs currentPath basePath ctx)
      |> (ctx: validate.fn-assertDefaultAttrsConflicts ctx)
      # Final layer state -> layer.LayerResult result
      |> (ctx: layer.LayerResult {
        path = path;
        flatShells   = ctx.subDirsAttrs.flatShells   // ctx.commonAttrs.flatShells   // ctx.defaultAttrs.flatShells;
        variantsTree = ctx.subDirsAttrs.variantsTree // ctx.commonAttrs.variantsTree // ctx.defaultAttrs.variantsTree;
        shellNames   = ctx.subDirsAttrs.shellNames   ++ ctx.commonAttrs.shellNames   ++ ctx.defaultAttrs.shellNames;
      });

    # Main processor
    # @currentPath: string (current active full path)
    # @basePath: string
    # @path: string (current active path)
    # @suffix: string
    fn-processMain = currentPath: basePath: path: suffix:
      (validate.fn-assertFileExists currentPath) # Fail-fast path validation
      |> (path: layer.fn-initialContext path basePath suffix)
      |> (ctx: layer.fn-processDirectory currentPath basePath path ctx);
  };

  # == TOP-LEVEL EXECUTION ==
  rootResult = layer.fn-processMain devDir fs.default-basePath fs.default-path suffix;

  # Global uniqueness validation (pipeline-style)
  _global_unique_validation = rootResult.shellNames
    |> (names: validate.fn-assertUniqueNames "GLOBAL NAMESPACE" names);

in rootResult.flatShells


