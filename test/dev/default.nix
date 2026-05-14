# @path: test/dev/default.nix
# @description: Root dev shell definitions — loaded by pdshells as the top-level default.nix.
#
# Receives from pdshells:
#   pkgs    — nixpkgs instance
#   inputs  — flake inputs
#   shared  — optional shared config passed to pdshells { shared = ...; }
#   dev     — variantsTree of all sub-directories and common files (use for combinFrom)

{ pkgs, inputs, shared ? {}, dev ? {}, ... }:
{
  # Shell name: "default"
  default = {
    buildInputs = with pkgs; [
      git
      curl
    ];
    shellHook = ''
      echo "Welcome to the default dev shell"
    '';
  };
}
