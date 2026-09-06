# Assertions-enabled Clang 23 shell for hunting the nondeterministic
# BMI-deserialization ICE.
#
# Rationale: the ASan scope (shells/stdexec-asan.nix) suppressed the crash
# entirely -- 0/20 at baseline against p ~ 0.25 on the plain toolchain, and
# still 0/N with quarantine and redzones minimized -- and produced no ASan
# report, so it is simultaneously blind and suppressive here. An assertions
# build leaves the allocator alone, so it perturbs heap layout far less and
# has a real chance of still reproducing the crash. If an internal assertion
# fires on the corrupted state, that is a deterministic oracle *and* a much
# stronger upstream report than a segfault in optimized code.
#
# Usage:
#   devshell stdexec-assert
#   cmake -S . -B build-assert -GNinja -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
#     <same flags as the normal modular build>
#   caffeinate -ims cmake --build build-assert
#   caffeinate -ims ./phase0-ice-rate.sh build-assert <TU-object-target> 20
{ pkgs, ... }:
let
  mkClangDevShell = import ../lib/mk-clang-dev-shell.nix { inherit pkgs; };
in
mkClangDevShell {
  # Resolves pkgs.llvmPackages_23_assert via mk-clang-dev-shell's
  # `llvmPackages_${toString clangVersion}` lookup.
  clangVersion = "23_assert";
  # A cache hit would skip running the diagnostic compiler entirely, which
  # defeats the purpose and silently inflates the apparent success rate.
  enableCcache = false;
  extraPackages = with pkgs; [
    cmake
    lldb
    ninja
  ];
}
