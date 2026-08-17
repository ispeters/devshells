{ pkgs, cladoscope }:
let
  cladoscopePkg = pkgs.python3Packages.buildPythonPackage {
    pname = "cladoscope";
    version = "0.1.0"; # keep in sync with cladoscope's pyproject.toml [project].version
    src = cladoscope; # flake input, github:ispeters/cladoscope, pinned via flake.lock
    pyproject = true;
    build-system = with pkgs.python3Packages; [ setuptools ];
    propagatedBuildInputs = with pkgs.python3Packages; [
      networkx
      libclang
    ];
    # nixpkgs' python3Packages.libclang builds a wheel whose own metadata
    # declares its distribution name as "clang" (see its setup.cfg), not
    # "libclang" -- it's the bindings-only flavor, packaged under nixpkgs'
    # "libclang" *attribute* name but not that PyPI distribution name.
    # cladoscope's pyproject.toml correctly depends on "libclang" (the real
    # PyPI package), so pythonRuntimeDepsCheckHook can't find a match by
    # name and fails the build, even though the propagated package above
    # does provide working clang.cindex bindings. Tell the hook to stop
    # enforcing that one declared name rather than removing the actual
    # dependency (which stays propagated just above).
    pythonRemoveDeps = [ "libclang" ];
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
