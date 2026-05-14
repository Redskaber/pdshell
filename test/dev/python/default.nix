# @path: test/dev/python/default.nix
# @description: Python sub-directory shell — default.nix for dev/python/.
#
# Receives from pdshells:
#   pkgs    — nixpkgs instance
#   inputs  — flake inputs
#   shared  — optional shared config
#   dev     — variantsTree: includes sub-dirs (renpy) and common files (machine)

{ pkgs, inputs, shared ? {}, dev ? {}, ... }:
{
  # Shell name: "python"
  default = {
    buildInputs = with pkgs; [
      python3
      python3Packages.pip
      python3Packages.virtualenv
    ];
    postInputsHook = ''
      export PYTHONDONTWRITEBYTECODE=1
      export PYTHONUNBUFFERED=1
    '';
    shellHook = ''
      echo "Python dev shell — $(python3 --version)"
    '';
  };
}
