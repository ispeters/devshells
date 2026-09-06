# ASan-instrumented Clang 23 shell for hunting compiler-internal heap bugs
# (currently: the nondeterministic BMI-deserialization ICE, suspected
# use-after-free read -- see llvm/llvm-project#191361). Not a daily-driver
# shell: the instrumented compiler is ~2x slower, and the first entry
# triggers a from-source rebuild of the whole instrumented scope.
#
# Usage sketch:
#   devshell stdexec-asan
#   cmake -S . -B build-asan -GNinja <same flags as the normal modular build>
#   cmake --build build-asan       # watch for ASan reports during warm-up
#   ./phase0-ice-rate.sh build-asan <TU-object-target> 20
{ pkgs, ... }:
let
  mkClangDevShell = import ../lib/mk-clang-dev-shell.nix { inherit pkgs; };
in
mkClangDevShell {
  # Resolves pkgs.llvmPackages_23_asan via mk-clang-dev-shell's
  # `llvmPackages_${toString clangVersion}` lookup.
  clangVersion = "23_asan";
  # ccache in front of a diagnostic compiler defeats the point: a cache hit
  # skips running the instrumented compiler entirely. ($CC/$CXX still come
  # from the shell's libcxxStdenv, which wraps the instrumented clang.)
  enableCcache = false;
  extraPackages = with pkgs; [
    cmake
    lldb
    ninja
  ];
  extraShellHook = ''
    # Quiet the known macOS nano-malloc-zone/ASan interaction for every
    # compiler invocation in this shell.
    export MallocNanoZone=0
    # Oracle-tuned defaults (override per-invocation by exporting your own):
    #   detect_leaks=0             -- LSan noise is not the target signal
    #   quarantine_size_mb=4096    -- big quarantine widens the window in
    #                                 which a stale read into freed memory is
    #                                 caught instead of landing in recycled
    #                                 storage (the default 256MB is small
    #                                 against a compiler's allocation churn)
    #   malloc_context_size=30     -- deep alloc/free stacks make the report
    #                                 upstream-ready
    #   detect_container_overflow=0 -- silence libc++ container-annotation
    #                                 false positives from the uninstrumented
    #                                 libc++.dylib boundary; container
    #                                 overflow is not the bug class under
    #                                 investigation
    export ASAN_OPTIONS="''${ASAN_OPTIONS:-detect_leaks=0:quarantine_size_mb=4096:malloc_context_size=30:detect_container_overflow=0}"
  '';
}
