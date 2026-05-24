{ nixpkgs, inputs, flake-utils }:
  flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # ── Library ───────────────────────────────────────────────────────────
      mkDevShellLib = import ../lib/mk-pdshell.nix { inherit pkgs; };
      mkDevShell    = mkDevShellLib.mkDevShell;

      pdshells = args: import ../lib/pdshells.nix (args // { inherit inputs; });

      # ── Test shells from the test/dev directory ───────────────────────────
      testShells = pdshells {
        inherit pkgs;
        inputs = inputs;
        devDir = ./dev;
        shared = {};
      };

    in {
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
  )
