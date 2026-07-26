{ pkgs }:
let
  mkClangDevShell = import ../lib/mk-clang-dev-shell.nix { inherit pkgs; };
  mkLlvmReleaseTool = import ../lib/mk-llvm-release-tool.nix { inherit pkgs; };

  clang-format-21_1_5 = mkLlvmReleaseTool {
    tool = "clang-format";
    version = "21.1.5";
    hash = "sha256-3OZKcYSJeecSE9RrPCDKpsF4AiLszmb4LLmw0h7Sjjs";
  };
in
mkClangDevShell {
  clangToolsOverride = {
    name = "clang-format";
    package = clang-format-21_1_5;
  };
  extraPackages = with pkgs; [
    cmake
    gersemi
    lldb
    ninja
  ];
}
