{ pkgs, ... }:
let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.networkx
    ps.libclang
    ps.pytest
  ]);
in
pkgs.mkShell {
  packages = [ pythonEnv ];
  shellHook = ''
    export CLADOSCOPE_DEV_REPO="''${CLADOSCOPE_DEV_REPO:-$HOME/git/cladoscope}"
    if [ -d "$CLADOSCOPE_DEV_REPO/src" ]; then
      export PYTHONPATH="$CLADOSCOPE_DEV_REPO/src''${PYTHONPATH:+:$PYTHONPATH}"
      cladoscope() { python3 -m cladoscope "$@"; }
      echo "cladoscope-dev: using local checkout at $CLADOSCOPE_DEV_REPO"
    else
      echo "cladoscope-dev: $CLADOSCOPE_DEV_REPO/src not found (set CLADOSCOPE_DEV_REPO to override)" >&2
      exit 1;
    fi
  '';
}
