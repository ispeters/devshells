{ pkgs, ... }:
let
  mkClangDevShell = import ../lib/mk-clang-dev-shell.nix { inherit pkgs; };
  mkLlvmReleaseTool = import ../lib/mk-llvm-release-tool.nix { inherit pkgs; };
  stdexec-ci = import ../lib/stdexec-ci { inherit pkgs; };
  # The Colima VM that shells/colima-docker.nix starts and stops; this shell
  # only talks to it.
  inherit (import ../lib/colima-profile.nix) dockerContext;

  clang-format-21_1_5 = mkLlvmReleaseTool {
    tool = "clang-format";
    version = "21.1.5";
    hash = "sha256-3OZKcYSJeecSE9RrPCDKpsF4AiLszmb4LLmw0h7Sjjs";
  };

  clangVersion = 23;
  llvmPackages = pkgs."llvmPackages_${toString clangVersion}";

  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.networkx
    ps.libclang # bindings only (pinned ~21.x upstream); we point it at our own libclang.dylib below
  ]);
in
mkClangDevShell {
  inherit clangVersion;
  clangToolsOverride = {
    name = "clang-format";
    package = clang-format-21_1_5;
  };
  extraPackages = with pkgs; [
    cmake
    docker-client
    gersemi
    lldb
    ninja
    pythonEnv
    stdexec-ci
  ];
  extraShellHook = ''
    export STDEXEC_LIBCLANG="${llvmPackages.libclang.lib}/lib/libclang.dylib"

    # Pin docker to the VM's context rather than whatever global context
    # colima last switched to, as shells/colima-docker.nix does.
    export DOCKER_CONTEXT=${dockerContext}

    # Keep CPM's downloads (Catch2, and Boost or Taskflow when enabled) in one
    # place shared by every build directory, instead of re-downloading them on
    # each fresh configure.
    export CPM_SOURCE_CACHE="''${CPM_SOURCE_CACHE:-$HOME/.cache/CPM}"
  '';
}
