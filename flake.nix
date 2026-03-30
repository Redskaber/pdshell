# @path: ~/projects/configs/nix-config/flake.nix
# @author: redskaber
# @datetime: 2026-03-30
# @directory: https://nix.dev/manual/nix/2.33/command-ref/new-cli/nix3-flake.html

{
  description = "Kilig(Redskaber)'s declarative pipeline dev shell environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-types.url = "github:Redskaber/nix-types";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    } @inputs:
    let
      export = {
        mk-pdshell = ./lib/pdshells.nix;
        pdshells = ./lib/pdshells.nix;
        test = import ./test { inherit inputs; pkgs = nixpkgs; };
      };
    in export;
}


