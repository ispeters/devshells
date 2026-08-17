{ pkgs, cladoscope }:
let
  cladoscopePkg = pkgs.python3Packages.buildPythonPackage {
    pname = "cladoscope";
    version = "0.1.0"; # keep in sync with cladoscope's pyproject.toml [project].version
    src = cladoscope; # flake input, github:ispeters/cladoscope, pinned via flake.lock
    pyproject = true;
    build-system = with pkgs.python3Packages; [ setuptools ];
    propagatedBuildInputs = with pkgs.python3Packages; [ networkx libclang ];
    doCheck = false;
  };

  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.pytest
    cladoscopePkg
  ]);
in
pkgs.mkShell {
  packages = [ pythonEnv ];
}
