{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [ nixfmt-rfc-style statix deadnix nixd ];
}
