# @path: test/dev/python/renpy/default.nix
# @description: Ren'Py visual-novel engine shell — default.nix for dev/python/renpy/.
#   Shell name: "python-renpy"
#
# Receives from pdshells:
#   pkgs    — nixpkgs instance
#   inputs  — flake inputs
#   shared  — optional shared config
#   dev     — variantsTree of ancestor directories

{ pkgs, inputs, shared ? {}, dev ? {}, ... }:
{
  # Shell name: "python-renpy"
  default = {
    buildInputs = with pkgs; [
      python3
      python3Packages.pygame-ce or python3Packages.pygame
      SDL2
      SDL2_image
      SDL2_mixer
      SDL2_ttf
    ];
    preShellHook = ''
      export SDL_VIDEODRIVER=''${SDL_VIDEODRIVER:-x11}
    '';
    postShellHook = ''
      echo "inputs: ${inputs.nix-types.outPath}"
    '';
  };
}
