{
  description = "Cross-project language/tool-specific devshells";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.cladoscope = {
    url = "github:ispeters/cladoscope";
    flake = false; # it's a plain Python package repo, not itself a flake
  };
  outputs =
    { nixpkgs, cladoscope, ... }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
      shellFiles = builtins.readDir ./shells;
      names = map (n: nixpkgs.lib.removeSuffix ".nix" n) (
        builtins.filter (n: shellFiles.${n} == "regular") (builtins.attrNames shellFiles)
      );
    in
    {
      devShells.${system} = nixpkgs.lib.genAttrs names (
        name: import ./shells/${name}.nix { inherit pkgs cladoscope; }
      );
    };
}
