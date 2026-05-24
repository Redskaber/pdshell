{
  description = "pdshell — Pipeline-driven Nix dev shell manager";

  inputs = {
    nixpkgs.url    = "github:NixOS/nixpkgs/nixos-unstable";
    nix-types.url  = "github:Redskaber/nix-types";   # provides enum
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nix-types, flake-utils, ... }@inputs:
  let
    # ── Library ───────────────────────────────────────────────────────────
    lib = {
      mk-pdshell = pkgs: import ./lib/mk-pdshell.nix pkgs;
      pdshells = args: import ./lib/pdshells.nix args;
    };
    tests = import ./test { inherit nixpkgs inputs flake-utils; };
    export = {
      inherit lib;
    } // tests;
  in export;
}
