# Assertions-enabled Clang built from a pinned llvm-project main commit,
# carrying only the ICS uninitialized-read assertion (see
# lib/llvm-trunk-overlay.nix).
#
# Purpose: the reduced two-file reproducer demonstrates the defect on 23.1.0.
# Source inspection says the same unguarded read exists on main, but that is a
# claim about code, not a measurement. This shell is how the measurement gets
# made -- and it is also the closest thing to what an upstream reviewer would
# build for themselves.
#
# Usage:
#   devshell stdexec-trunk-assert
#   cd ~/ics-repro
#   clang++ -std=c++23 -stdlib=libc++ -O0 -x c++-module mod.cppm \
#     --precompile -o stdexec.pcm
#   clang++ -std=c++23 -stdlib=libc++ -O0 -fsyntax-only \
#     -fmodule-file=stdexec=stdexec.pcm red3.cpp
#
# The second command should abort on the assertion. If it compiles clean, the
# window is not entered on main and that is a real finding -- the read is
# reachable on 23.1.0 but not on trunk -- which changes what the report should
# claim.
#
# Caveat worth knowing before you spend the build: nixpkgs' mkLLVMPackages at
# nixos-26.05 has only ever been exercised against release tags. A main
# snapshot can fail for reasons that have nothing to do with this bug (moved
# CMake options, new subproject requirements, a runtimes-layout change).
# Treat a build failure here as a nixpkgs-vs-trunk problem first.
{ pkgs, ... }:
let
  mkClangDevShell = import ../lib/mk-clang-dev-shell.nix { inherit pkgs; };
in
mkClangDevShell {
  # Resolves pkgs.llvmPackages_24_trunk_assert via mk-clang-dev-shell's
  # `llvmPackages_${toString clangVersion}` lookup.
  clangVersion = "24_trunk_assert";
  # Same reasoning as stdexec-assert-minimal: a cache hit would skip running
  # the diagnostic compiler and silently inflate the apparent success rate.
  enableCcache = false;
  extraPackages = with pkgs; [
    cmake
    lldb
    ninja
  ];
}
