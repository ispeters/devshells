# A nixpkgs overlay adding pkgs.llvmPackages_23, built from source.
#
# Usage: pass `import ./lib/llvm23-overlay.nix` (or, from another flake,
# `import "${devshells}/lib/llvm23-overlay.nix"`) in the `overlays` list of
# your own `import nixpkgs { ... }` call. It must be an overlay applied at
# pkgs-construction time -- see the note below on why a local `let` binding
# elsewhere doesn't work -- so it can't be consumed any other way (e.g. it
# is not importable as a plain function taking `pkgs` the way
# mk-clang-dev-shell.nix is).
final: prev: {
  # pkgs.llvmPackages_23 doesn't exist at nixos-26.05 (293d6abe) -- the
  # internal versions table only has a stale "23.0.0-git" dev-snapshot
  # entry, unwired to any llvmPackages_23 alias. Build 23.1.0 from source
  # via mkLLVMPackages (the same generic per-major-version builder nixpkgs
  # uses internally), pointed at the real release tag.
  #
  # This has to be an overlay, not a local `let` binding in a consuming
  # shell file: nixpkgs' cross-compilation splicing machinery
  # (generateSplicesForMkScope) requires a same-named attribute to exist in
  # pkgs.pkgsBuildBuild/pkgsBuildHost/pkgsHostHost/etc, not just in pkgs
  # itself -- even for a purely native, non-cross build. Overlays are the
  # only thing that propagates into all of those scopes uniformly.
  llvmPackages_23 =
    (
      (final.mkLLVMPackages {
        name = "23";
        version = "23.1.0";
        gitRelease = {
          rev = "llvmorg-23.1.0";
          rev-version = "23.1.0";
          sha256 = "sha256-Astfi1UDDcydyws3Q1sELqho/PxiNN/tvCtmCGj5FoE=";
        };
      }).value
    ).overrideScope (
      lFinal: lPrev: {
        # LLVM's own test suite includes tests (dsymutil/codesign.test)
        # that shell out to the real macOS `codesign`, unavailable inside
        # Nix's sandboxed Darwin build. nixpkgs' compiler-rt derivation
        # hits the identical problem and works around it by disabling the
        # codesign check outright rather than providing a working
        # substitute; common/llvm/default.nix has no equivalent exclusion
        # for this specific test yet at this pin (unsurprising, since
        # nixpkgs hasn't built LLVM 23 itself). Rather than patch out
        # individual failing tests one at a time across a 66k-test suite,
        # skip it entirely for this locally-built toolchain.
        #
        # NOTE: override libllvm, not llvm -- llvm is merely an alias
        # (`llvm = self.libllvm;` in common/default.nix) for backwards
        # compatibility with when `llvm` had the binaries. Overriding the
        # alias itself doesn't touch what libllvm's own internal
        # self-references resolve to, so doCheck stayed true.
        libllvm = lPrev.libllvm.overrideAttrs (old: { doCheck = false; });
      }
    );

  # ASan-instrumented variant of the same toolchain. The compiler *binaries*
  # carry AddressSanitizer; code they compile is entirely unaffected. This is
  # a diagnostic instrument for catching compiler-internal heap bugs (e.g.
  # stale reads into freed deserialization state during BMI import), not a
  # daily-driver toolchain: expect slower compiles and a from-scratch build
  # of the whole scope on first use.
  #
  # IMPORTANT: this is a *separate mkLLVMPackages instantiation*, not an
  # `llvmPackages_23.overrideScope`. overrideScope rebinds only the scope's
  # `self`, but the pieces that decide which compiler you actually get are
  # reached through `buildLlvmPackages`, which common/default.nix binds to
  # `otherSplices.selfBuildHost` -- fixed at makeScopeWithSplicing' time from
  # the splices, never from `self`. In particular
  #
  #     libcxxStdenv = overrideCC stdenv buildLlvmPackages.libcxxClang;
  #
  # so an overrideScope-based variant silently hands back the *un*instrumented
  # clang: the scope's own libclang is instrumented, but nothing the shell
  # consumes refers to it. (Symptom: the build takes hours, then
  # `ASAN_OPTIONS=help=1 clang++ --version` prints no option dump.)
  #
  # Instantiating with `name = "23_asan"` makes generateSplicesForMkScope
  # generate splices for the attribute name `llvmPackages_23_asan`, so
  # `buildLlvmPackages` resolves to *this* overlay attribute -- including the
  # overrideScope layer below, since the attribute is bound to the whole
  # expression. That closes the loop and makes the instrumentation stick.
  llvmPackages_23_asan =
    (
      (final.mkLLVMPackages {
        name = "23_asan";
        version = "23.1.0";
        gitRelease = {
          rev = "llvmorg-23.1.0";
          rev-version = "23.1.0";
          sha256 = "sha256-Astfi1UDDcydyws3Q1sELqho/PxiNN/tvCtmCGj5FoE=";
        };
      }).value.override {
        # Build the instrumented toolchain *with* the from-source Clang 23,
        # not with the default (LLVM 21) Darwin stdenv.
        #
        # LLVM_USE_SANITIZER=Address makes the build compile LLVM's own sources
        # with -fsanitize=address, and the ASan runtime that gets linked in
        # comes from whichever compiler performs that build. With the default
        # stdenv that is compiler-rt 21.1.8, whose Darwin ASan runtime predates
        # llvm/llvm-project#167797 ("[sanitizer_common] Add darwin-specific
        # MemoryRangeIsAvailable", Nov 2025). The pre-#167797 runtime allocates
        # while walking the memory map during InitializeShadowMemory
        # (MemoryMappingLayout -> get_dyld_hdr -> dyld_shared_cache_iterate_text
        # -> _Block_copy -> malloc), and since malloc is already interposed that
        # re-enters AsanInitFromRtl on the same thread and spins forever on the
        # non-recursive StaticSpinMutex. Symptom: *every* binary produced by the
        # instrumented toolchain -- including `clang --version` itself -- hangs
        # at 100% CPU before main, on macOS 26.
        #
        # Verified empirically: `otool -L` on the instrumented clang showed
        # compiler-rt-libc-21.1.8's libclang_rt.asan_osx_dynamic.dylib, while an
        # ASan hello-world built in the plain stdexec shell links
        # compiler-rt-libc-23.1.0's and runs fine.
        #
        # `.override` (rather than an argument to mkLLVMPackages) is the
        # supported channel here: mkPackage's argument set has no ellipsis, but
        # common/default.nix takes `stdenv`, and nixpkgs documents
        # `(llvmPackages.override { ... })` for exactly this.
        stdenv = final.llvmPackages_23.libcxxStdenv;
      }
    ).overrideScope
      (
        lFinal: lPrev:
        let
          instrument =
            drv:
            drv.overrideAttrs (old: {
              cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DLLVM_USE_SANITIZER=Address" ];
              # Fortify's *_chk interposers fight ASan's interceptors;
              # disabling all hardening is standard for sanitized builds.
              hardeningDisable = [ "all" ];
              # No test suites under ASan: slow, and interceptor-related
              # noise produces failures unrelated to what we're hunting.
              # (This also covers the sandboxed-codesign test that the
              # plain llvmPackages_23 scope disables for the same reason.)
              doCheck = false;
            });
        in
        {
          # Both libllvm and libclang are instrumented, deliberately
          # uniformly: mixing instrumented and uninstrumented dylibs that
          # pass libc++ containers across their boundary invites
          # container-annotation false positives. (Belt-and-suspenders for
          # the same issue at the libc++.dylib boundary: the stdexec-asan
          # shell exports detect_container_overflow=0 by default.)
          #
          # Benchmarks are off purely as dead weight: nothing here needs
          # them, and google/benchmark's cxx_feature_check does a CMake
          # try_run (it compiles and *executes* a probe binary during
          # configure), which is a needless extra way for an instrumented
          # binary to misbehave. NOTE: an earlier version of this file
          # claimed that try_run was the cause of a configure hang. That was
          # wrong -- the hang was the 21.1.8 ASan runtime deadlocking in
          # every instrumented binary, fixed by the stdenv override above.
          libllvm = (instrument lPrev.libllvm).overrideAttrs (old: {
            cmakeFlags = old.cmakeFlags ++ [ "-DLLVM_INCLUDE_BENCHMARKS=OFF" ];
          });
          libclang = instrument lPrev.libclang;
        }
      );
}
