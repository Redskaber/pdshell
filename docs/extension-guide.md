# pdshell — Extension Guide

> Version 2.2.0 · How to extend pdshell without modifying core modules.

---

## Principle: Dependency Inversion

All extension points are injected via function parameters.
Core modules depend on protocol contracts — not on concrete implementations.

There are now **three injectable strategies** in `mkDevShell`:

| Parameter              | Protocol                                      | Default                                  |
| ---------------------- | --------------------------------------------- | ---------------------------------------- |
| `_resolveStrategy`     | `entry:attrset → config:attrset`              | `resolveStrategy.default`                |
| `_mergeStrategy`       | `base:[pkg] → extracted:[pkg] → merged:[pkg]` | `mergeStrategy.unique`                   |
| `_hookComposeStrategy` | `args → in → resolvedCombin → composedPhases` | `hookComposer.fn-defaultComposeStrategy` |

---

## 1. Custom Resolve Strategy

Protocol: `entry:attrset → config:attrset`

```nix
# Unwrap entries that use a non-standard "cfg" wrapper key
myResolveStrategy = entry:
  if builtins.hasAttr "cfg" entry then entry.cfg
  else resolveStrategy.default entry;   # fall through to default

shell = mkDevShell {
  _resolveStrategy = myResolveStrategy;
  combinFrom = [ { cfg = { buildInputs = [ pkgs.git ]; }; } ];
};
```

---

## 2. Custom Merge Strategy

Protocol: `base:[pkg] → extracted:[pkg] → [pkg]`

```nix
# Allow duplicates — no deduplication
orderedMerge = base: extracted: base ++ extracted;

shell = mkDevShell {
  _mergeStrategy = orderedMerge;
  buildInputs    = [ pkgs.git ];
  combinFrom     = [ { buildInputs = [ pkgs.curl ]; } ];
};
```

Built-in strategies:

| Name                     | Behaviour                             |
| ------------------------ | ------------------------------------- |
| `mergeStrategy.unique`   | Concatenate + deduplicate (default)   |
| `mergeStrategy.prepend`  | `combinFrom` items first, deduplicate |
| `mergeStrategy.baseOnly` | Ignore `combinFrom` inputs            |

---

## 3. Custom Hook Compose Strategy

Protocol: `args → in:[hookAttrset] → resolvedCombin:[attrset] → composedPhases`

`composedPhases` must be an attrset with exactly:
`{ preInputs, postInputs, inheritedShell, preShell, postShell }` — all strings.

```nix
# Reverse the inherited hook order (last combinFrom wins)
reverseInheritedCompose = args: in: resolvedCombin:
  let
    base = hookComposer.fn-defaultComposeStrategy args in resolvedCombin;
  in base // {
    preInputs = hookComposer.fn-composePhase
      "preInputsHook"
      "preInputsHookFn"
      (lib.reverseList (map (h: h.preInputsHook) in))
      (args.preInputsHook or "")
      (args.preInputsHookFn or null);
  };

shell = mkDevShell {
  _hookComposeStrategy = reverseInheritedCompose;
  combinFrom = [ pluginA pluginB ];
};
```

---

## 4. Dynamic Hook Functions

Each `*HookFn` receives `{ pkgs }` and must return `string | null`.

```nix
shell = mkDevShell {
  preShellHookFn = { pkgs }: ''
    export RUST_SRC_PATH="${pkgs.rustPlatform.rustLibSrc}"
    echo "Rust dev environment ready"
  '';

  postShellHookFn = { pkgs }: null;   # no-op; null is valid
};
```

---

## 5. Composing Shells via combinFrom

```nix
# plugins/base.nix
{ pkgs, ... }:
{
  default = {
    buildInputs  = [ pkgs.git pkgs.curl pkgs.jq ];
    preShellHook = "export EDITOR=nvim";
  };
}

# plugins/node.nix
{ pkgs, ... }:
{
  default = {
    buildInputs    = [ pkgs.nodejs pkgs.yarn ];
    postInputsHook = ''
      export NODE_ENV=development
      export PATH="$PWD/node_modules/.bin:$PATH"
    '';
  };
}

# dev/default.nix  (loaded by pdshells)
{ pkgs, dev, ... }:
{
  # Shell named "frontend" — composes base + node
  frontend = {
    combinFrom = [ dev.base dev.node ];
    shellHook  = "echo 'frontend shell'";
  };
}
```

---

## 6. Org-Wide Defaults Wrapper

```nix
# lib/mkOrgShell.nix
{ pkgs, mkDevShell, orgPkgs }:
args:
  mkDevShell ({
    buildInputs    = [ pkgs.git pkgs.gnupg pkgs.sops ];
    _mergeStrategy = mergeStrategy.prepend;
    preShellHook   = ''
      eval $(sops -d secrets/env.yaml 2>/dev/null || true)
    '';
  } // args);
```

---

## 7. Custom File Process Strategy (pdshells)

Add a new category of files processed alongside the built-in common/default strategies:

```nix
SharedStrategy = layer.FileProcessStrategy.FileStrategy {
  attrType              = fs.AttrType.Common;
  targetField           = "sharedAttrs";
  fn-getFileList        = _path: _suffix: [ "shared.nix" ];
  fn-getSubVariantsTree = _: {};           # shared files see no prior context
  fn-validationContext  = currentPath: "SHARED FILE(${currentPath})";
  fn-aggregateVariantsTree = fileResults:
    (builtins.head fileResults).variantsTree;
};
```

Note: `fn-getFileList` now receives both `currentPath` and `currentSuffix` (v2.2+).

---

## 8. Shell Override at the Variant Level

The `shell` key is honoured at the variant level because `pdshells` calls
`mkDevShell (variantAttrset // { name = ...; })` — so any `shell` in a variant
config is forwarded to `mkDevShell` and fully processed:

```nix
# dev/python/machine.nix
{ pkgs, ... }:
{
  default = {
    buildInputs = [ pkgs.python3 pkgs.zsh ];
    shell       = "zsh";   # exec'd after all hooks
  };
}
# → shell name "python-machine" will exec zsh after hooks run
```

---

## 9. Accessing Internals for Testing

`mk-pdshell.nix` exports all internal modules:

```nix
let
  subject = import ./lib/mk-pdshell.nix { inherit pkgs; };
in {
  # Individual module tests
  test-resolveDefault =
    subject.resolveStrategy.default { default = { buildInputs = [ pkgs.git ]; }; };

  test-mergeUnique =
    subject.mergeStrategy.unique [ pkgs.git ] [ pkgs.git pkgs.curl ];

  # Hook compose strategy test (new in v2.2)
  test-hookCompose =
    subject.hookComposer.fn-defaultComposeStrategy
      { preInputsHook = "echo pre"; }
      []     # no inherited hooks
      [];    # no resolvedCombin

  # Protocol constants
  test-hookPhase   = subject.HookPhase.PRE_INPUTS;    # "preInputsHook"
  test-hookFnField = subject.HookFnField.PRE_INPUTS;  # "preInputsHookFn"

  # Full pipeline
  test-mkDevShell = subject.mkDevShell {
    buildInputs = [ pkgs.git ];
    shellHook   = "echo test";
  };
}
```
