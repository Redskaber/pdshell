# @path: test/dev/cpp/default.nix
# @description: C++ sub-directory shell — loaded by pdshells as default.nix for dev/cpp/.
#
# Receives from pdshells:
#   pkgs    — nixpkgs instance
#   inputs  — flake inputs
#   shared  — optional shared config
#   dev     — variantsTree including parent-level shells (for combinFrom)

{ pkgs, inputs, shared ? {}, dev ? {}, ... }:
{
  # Shell name: "cpp"  (directory name, variant "default" → omitted)
  default = {
    buildInputs = with pkgs; [
      gcc
      cmake
      ninja
      gdb
    ];
    preShellHook = ''
      export CC=${pkgs.gcc}/bin/gcc
      export CXX=${pkgs.gcc}/bin/g++
    '';
    shellHook = ''
      echo "C++ dev shell — gcc $(gcc --version | head -1)"
    '';
  };
}
