{ pkgs, ... }:
pkgs.mkShell {
  packages = with pkgs; [
    deadnix
    nixd
    nixfmt
    statix
  ];
}
