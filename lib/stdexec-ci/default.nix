# `stdexec-ci`: runs rows of stdexec's GitHub Actions CI matrix locally, in
# the Colima VM's Docker (see lib/colima-profile.nix). The VM itself is owned
# by shells/colima-docker.nix; this only talks to it.
{ pkgs }:
let
  colima = import ../colima-profile.nix;
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in
pkgs.writeShellApplication {
  name = "stdexec-ci";
  runtimeInputs = [
    python
    pkgs.docker-client
    pkgs.git
  ];
  text = ''
    export STDEXEC_CI_DOCKER_CONTEXT="''${STDEXEC_CI_DOCKER_CONTEXT:-${colima.dockerContext}}"
    exec python3 ${./stdexec_ci.py} "$@"
  '';
}
