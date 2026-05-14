{
  description = "pdshell — Pipeline-driven Nix dev shell manager";

  inputs = {
    nixpkgs.url    = "github:NixOS/nixpkgs/nixos-unstable";
    nix-types.url  = "github:redskaber/nix-types";   # provides enum
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nix-types, flake-utils, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # ── Library ───────────────────────────────────────────────────────────
        mkDevShellLib = import ./lib/mk-pdshell.nix { inherit pkgs; };
        mkDevShell    = mkDevShellLib.mkDevShell;

        pdshells = args: import ./lib/pdshells.nix (args // { inherit inputs; });

        # ── Test shells from the test/dev directory ───────────────────────────
        testShells = pdshells {
          inherit pkgs;
          devDir = ./test/dev;
          shared = {};
        };

      in {
        # ── Exported library surface ──────────────────────────────────────────
        lib = {
          inherit mkDevShell pdshells;

          # Internals re-exported for downstream testing/extension
          inherit (mkDevShellLib)
            validate resolveStrategy extractor mergeStrategy hookComposer pipeline
            HookPhase HookFnField ContextPhase ShellKey;
        };

        # ── devShells for CI / contributors ──────────────────────────────────
        devShells = testShells // {
          # Convenience alias for nix develop
          default = testShells.default or (mkDevShell {
            name        = "pdshell-dev";
            buildInputs = [ pkgs.nix pkgs.git ];
            shellHook   = ''echo "pdshell dev shell — run: nix flake check"'';
          });
        };

        # ── Checks (basic smoke tests) ────────────────────────────────────────
        checks = {
          # Ensure all test shells evaluate without error
          test-shells-eval = pkgs.runCommand "test-shells-eval" {} ''
            echo "Test shells evaluated successfully"
            echo "${builtins.concatStringsSep "\n" (builtins.attrNames testShells)}" > $out
          '';
        };
      }
    );
}
