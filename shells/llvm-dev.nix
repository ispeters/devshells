# Host toolchain for building llvm-project itself, for upstream contribution
# work (e.g. the fix for llvm/llvm-project#191361).
#
# Deliberately NOT built on lib/mk-clang-dev-shell.nix. That helper exists to
# compile our own C++20/23 module code with a specific pinned Clang, and three
# of the things it does are wrong here:
#
#   * It pins the stdenv to llvmPackages_<N>.libcxxStdenv -- the from-source
#     Clang/libc++ we are testing *with*. The compiler used to *build* LLVM is
#     an independent choice, and conflating the two makes it hard to say which
#     Clang any given result came from. It would also rebuild a whole
#     from-source toolchain just to act as a host compiler.
#   * It exports CPLUS_INCLUDE_PATH to work around the clang-scan-deps nixpkgs
#     bug (NixOS/nixpkgs#452260). LLVM's own CMake configure checks have no
#     need of it, and an unexpected header search path is exactly the sort of
#     thing that makes a configure failure hard to read.
#   * It exports CC/CXX pointing at ccache-wrapped clang. LLVM has its own
#     ccache integration (-DLLVM_CCACHE_BUILD=ON); doing both is redundant.
#
# The default stdenv (Apple Clang, via the SDK) is a fine host compiler for
# LLVM and is what upstream expects on macOS, so this is a plain mkShell.
#
# Usage:
#   devshell llvm-dev
#   cd <llvm-project checkout>
#   cmake -S llvm -B build -G Ninja \
#     -DCMAKE_BUILD_TYPE=Release \
#     -DLLVM_ENABLE_ASSERTIONS=ON \
#     -DLLVM_ENABLE_PROJECTS=clang \
#     -DLLVM_TARGETS_TO_BUILD='AArch64;X86' \
#     -DLLVM_CCACHE_BUILD=ON \
#     -DLLVM_INCLUDE_BENCHMARKS=OFF \
#     -DLLVM_INCLUDE_EXAMPLES=OFF \
#     -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
#     -DCLANG_ENABLE_ARCMT=OFF
#   caffeinate -ims ninja -C build clang
#   ninja -C build check-clang
#
# LLVM_ENABLE_ASSERTIONS=ON is not optional for this work: it defaults to OFF
# for Release builds, and assert()-guarded code (including the provisional-key
# assertions in the #191361 patch) compiles out entirely without it. LLVM
# arranges for -UNDEBUG when it is on, so `#ifndef NDEBUG` is the correct
# spelling of "assertions enabled".
#
# X86 is built alongside AArch64 because a good number of clang/test cases pin
# an explicit x86_64 triple; without that backend registered they fail for
# reasons unrelated to whatever you are working on.
{ pkgs, ... }:
pkgs.mkShell {
  packages = with pkgs; [
    ccache
    cmake
    lldb
    ninja
    python3
  ];

  shellHook = ''
    # A from-scratch LLVM build is large enough to evict most of a shared
    # ccache, so this defaults to its own directory rather than the
    # NIX_DEVSHELLS_CCACHE_DIR path shared by the project shells. Override
    # with NIX_DEVSHELLS_LLVM_CCACHE_DIR if you want it somewhere else, or
    # point it at the shared path if you would rather they share after all.
    #
    # As in lib/mk-clang-dev-shell.nix, CCACHE_MAXSIZE is deliberately not
    # exported with a default: env var beats CCACHE_DIR/ccache.conf, so doing
    # so would silently undo any persisted size every time you enter the
    # shell. A dedicated cache for LLVM wants to be large -- set it once with
    # `ccache --max-size=...` after first entering the shell.
    export CCACHE_DIR="''${NIX_DEVSHELLS_LLVM_CCACHE_DIR:-$HOME/.cache/nix-devshells-ccache-llvm}"
    if [ -n "''${NIX_DEVSHELLS_CCACHE_MAX_SIZE:-}" ]; then
      export CCACHE_MAXSIZE="$NIX_DEVSHELLS_CCACHE_MAX_SIZE"
    fi
  ''
  + builtins.readFile ../lib/debugserver-shellhook.sh;
}
