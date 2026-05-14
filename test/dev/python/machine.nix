# @path: test/dev/python/machine.nix
# @description: Machine-learning Python shell — common file for dev/python/.
#   File base "machine" → shell name "python-machine" (variant "default" omitted).
#
# Demonstrates:
#   • postInputsHook for environment variable setup
#   • shell override: replaces the interactive shell with zsh after all hooks run
#
# Receives from pdshells:
#   pkgs    — nixpkgs instance
#   inputs  — flake inputs
#   shared  — optional shared config
#   dev     — variantsTree of sibling sub-directories (subDirs only at this stage)

{ pkgs, inputs, shared ? {}, dev ? {}, ... }:
{
  # Shell name: "python-machine"
  default = {
    buildInputs = with pkgs; [
      python3
      python3Packages.numpy
      python3Packages.scipy
      python3Packages.matplotlib
      zsh   # required in PATH for the shell override below
    ];
    postInputsHook = ''
      export MPLBACKEND=Agg
    '';
    shellHook = ''
      echo "Python ML shell — $(python3 --version)"
    '';
    # shell override: exec'd after all hooks, replaces the current process.
    shell = "zsh";
  };
}
