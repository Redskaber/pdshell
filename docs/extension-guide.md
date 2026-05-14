# pdshell — Extension Guide

> How to extend pdshell without modifying core modules.

---

## Principle: Dependency Inversion

All extension points are injected via function parameters.
Core modules depend on protocol contracts — not on concrete implementations.

---

## 1. Custom Resolve Strategy

Protocol: `entry:attrset → config:attrset`

```nix
# Unwrap entries that use a non-standard "cfg" wrapper key
myResolveStrategy = entry:
  if builtins.hasAttr "cfg" entry then entry.cfg
  else resolveStrategy.default entry;   # fall through

shell = mkDevShell {
  _resolveStrategy = myResolveStrategy;
  combinFrom = [ { cfg = { buildInputs = [ pkgs.git ]; }; } ];
};
```

---

## 2. Custom Merge Strategy

Protocol: `base:[pkg] → extracted:[pkg] → [pkg]`

```nix
# Allow duplicates (no deduplication)
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

## 3. Dynamic Hook Functions

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

## 4. Composing Shells via combinFrom

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

## 5. Org-Wide Defaults Wrapper

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

## 6. Custom File Process Strategy (pdshells)

Add a new category of files processed alongside the built-in common/default strategies:

```nix
SharedStrategy = layer.FileProcessStrategy.FileStrategy {
  attrType              = fs.AttrType.Common;
  targetField           = "sharedAttrs";
  fn-getFileList        = _: [ "shared.nix" ];
  fn-getSubVariantsTree = _: {};           # shared files see no prior context
  fn-validationContext  = currentPath: "SHARED FILE(${currentPath})";
  fn-aggregateVariantsTree = fileResults:
    (builtins.head fileResults).variantsTree;
};
```

---

## 7. Accessing Internals for Testing

`mk-pdshell.nix` exports all internal modules:

```nix
let
  subject = import ./lib/dev/mk-pdshell.nix { inherit pkgs; };
in {
  # Individual module tests
  test-resolveDefault =
    subject.resolveStrategy.default { default = { buildInputs = [ pkgs.git ]; }; };

  test-mergeUnique =
    subject.mergeStrategy.unique [ pkgs.git ] [ pkgs.git pkgs.curl ];

  # Protocol constants
  test-hookPhase = subject.HookPhase.PRE_INPUTS;   # "preInputsHook"
  test-hookFnField = subject.HookFnField.PRE_INPUTS; # "preInputsHookFn"

  # Full pipeline
  test-mkDevShell = subject.mkDevShell {
    buildInputs = [ pkgs.git ];
    shellHook   = "echo test";
  };
}
```
