{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [ nixfmt statix deadnix nixd ];
}
