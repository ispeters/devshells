{ pkgs }:
# cladoscope's own runtime dependencies, kept in sync with the
# [project.dependencies] list in cladoscope's pyproject.toml. Both
# shells/cladoscope.nix (installs cladoscope as a package) and
# shells/cladoscope-dev.nix (runs cladoscope from a local checkout via
# PYTHONPATH, without packaging it) need exactly this list, so it lives here
# once instead of as two hand-maintained copies.
with pkgs.python3Packages;
[
  networkx
  libclang
]
