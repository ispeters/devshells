{ pkgs, ... }:
let
  # A named profile whose VM outlives the shell. Stopping (rather than
  # deleting) it on exit keeps its disk, so pulled images and anything else
  # stored in the VM survive between sessions.
  #
  # The resources are sized for building Clang from source inside an amd64
  # container under Rosetta. `colima start` applies explicitly passed
  # --cpus/--memory to an existing stopped profile, so changing these takes
  # effect on the next shell entry; disk can only grow. To reclaim the space:
  #     colima delete --profile stdexec-repro
  profile = "stdexec-repro";
  cpus = 8;
  memoryGiB = 16;
in
pkgs.mkShell {
  packages = with pkgs; [
    colima
    docker
  ];

  shellHook = ''
    LOCKFILE="''${TMPDIR:-/tmp}/colima-docker-devshell-${profile}.lock"

    if [[ -f "$LOCKFILE" ]]; then
      owner_pid=$(cat "$LOCKFILE")
      if kill -0 "$owner_pid" 2>/dev/null; then
        echo "error: colima-docker devshell is already active (owning shell pid $owner_pid)." >&2
        echo "Running a second instance would tear down the VM out from under the first" >&2
        echo "one when either shell exits. Use the existing session, or if pid $owner_pid" >&2
        echo "is stale/gone, remove $LOCKFILE and re-enter." >&2
        return 1
      else
        echo "warning: stale lock from dead pid $owner_pid -- cleaning up." >&2
        rm -f "$LOCKFILE"
      fi
    fi

    if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
      echo "warning: Rosetta doesn't appear to be installed. amd64 containers" >&2
      echo "('docker run --platform linux/amd64 ...') will fail or silently fall" >&2
      echo "back to slow QEMU emulation. One-time fix (not managed by this shell):" >&2
      echo "    softwareupdate --install-rosetta --agree-to-license" >&2
    fi

    echo $$ > "$LOCKFILE"
    colima start --profile ${profile} --vm-type vz --vz-rosetta \
      --cpus ${toString cpus} --memory ${toString memoryGiB}

    # colima switches the global docker context on start; pin this shell to
    # the profile's context so it doesn't depend on that global state.
    export DOCKER_CONTEXT=colima-${profile}

    cleanup() {
      colima stop --profile ${profile}
      rm -f "$LOCKFILE"
    }
    trap cleanup EXIT
  '';
}
