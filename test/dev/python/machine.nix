# @path: ~/projects/configs/nix-config/lib/dev/default.nix
# @description: Example top-level dev shell definitions
# This file is imported by pdshells.nix as the "default.nix" for the root dev directory.
# It receives:
#   pkgs    — nixpkgs
#   inputs  — flake inputs
#   shared  — shared config passed to pdshells
#   dev     — variantsTree of all sub-directories and common files (for combinFrom)

{ pkgs, inputs, shared ? {}, dev ? {}, ... }:
{
  # The "default" key produces shell name: "default"
  # Additional keys produce: "rust", "go", etc.
  default = {
    shell = "zsh";
    buildInputs = with pkgs; [
      git
      curl
    ];

    shellHook = ''
      echo "Welcome to the default dev shell"
    '';
  };
}
