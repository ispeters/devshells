{ pkgs, ... }:
let
  cladoscopeDeps = import ../lib/cladoscope-python-deps.nix { inherit pkgs; };
  providedNames = builtins.concatStringsSep " " (map (p: p.pname) cladoscopeDeps);
  pythonEnv = pkgs.python3.withPackages (ps: cladoscopeDeps ++ [ ps.pytest ]);
in
pkgs.mkShell {
  packages = [ pythonEnv ];
  shellHook = ''
    export CLADOSCOPE_DEV_REPO="''${CLADOSCOPE_DEV_REPO:-$HOME/git/cladoscope}"
    if [ -d "$CLADOSCOPE_DEV_REPO/src" ]; then
      export PYTHONPATH="$CLADOSCOPE_DEV_REPO/src''${PYTHONPATH:+:$PYTHONPATH}"
      cladoscope() { python3 -m cladoscope "$@"; }
      echo "cladoscope-dev: using local checkout at $CLADOSCOPE_DEV_REPO"

      # lib/cladoscope-python-deps.nix is only known to be right for
      # whatever cladoscope commit flake.lock pins (see
      # shells/cladoscope.nix) -- it can't know about a dependency
      # $CLADOSCOPE_DEV_REPO has added locally, ahead of that pin, since
      # which checkout is in play is only knowable here at shell-entry
      # time, not at flake-eval time. Cross-check against the checkout's
      # own pyproject.toml now, so a real gap is a loud warning on entry
      # rather than a ModuleNotFoundError whenever you happen to exercise
      # the new import.
      if [ -f "$CLADOSCOPE_DEV_REPO/pyproject.toml" ]; then
        python3 - "$CLADOSCOPE_DEV_REPO/pyproject.toml" "${providedNames}" <<'PYEOF'
''
    + builtins.readFile ../lib/check-cladoscope-deps.py
    + ''
PYEOF
      fi
    else
      echo "cladoscope-dev: $CLADOSCOPE_DEV_REPO/src not found (set CLADOSCOPE_DEV_REPO to override)" >&2
      exit 1;
    fi
  '';
}
