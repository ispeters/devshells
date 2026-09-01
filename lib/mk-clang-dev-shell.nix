{ pkgs }:
{
  clangVersion ? 22,
  extraPackages ? [ ],
  # e.g. { name = "clang-format"; package = someDerivation; }
  clangToolsOverride ? null,
  extraShellHook ? "",
  # Wraps clang/clang++ with ccache and exports CC/CXX, for interactive
  # builds run by hand inside the shell (cmake/ninja, etc).
  enableCcache ? true,
}:
let
  llvmPackages = pkgs."llvmPackages_${toString clangVersion}";

  clang-tools =
    if clangToolsOverride == null then
      llvmPackages.clang-tools
    else
      pkgs.symlinkJoin {
        name = "clang-tools-${toString clangVersion}-with-${clangToolsOverride.name}-override";
        paths = [ llvmPackages.clang-tools ];
        postBuild = ''
          rm $out/bin/${clangToolsOverride.name}
          ln -s ${clangToolsOverride.package}/bin/${clangToolsOverride.name} $out/bin/${clangToolsOverride.name}
        '';
      };

  cachedClang = pkgs.writeShellScriptBin "clang" ''
    exec ${pkgs.ccache}/bin/ccache ${llvmPackages.libcxxClang}/bin/clang "$@"
  '';
  cachedClangxx = pkgs.writeShellScriptBin "clang++" ''
    exec ${pkgs.ccache}/bin/ccache ${llvmPackages.libcxxClang}/bin/clang++ "$@"
  '';
  # NOTE: llvmPackages.clang deliberately means something different on Darwin
  # than elsewhere: pkgs/development/compilers/llvm/common/default.nix binds
  # it to `systemLibcxxClang` (libcxx = darwin.libcxx, i.e. Apple's ambient
  # system libc++, tracking the host's Xcode/CLT/SDK) rather than this
  # package set's own from-source libcxx. `libcxxClang` is the definition
  # that's actually wired to `targetLlvmPackages.libcxx` -- the same one
  # `libcxxStdenv.cc` (and hence plain `clang++` on PATH) already uses -- so
  # this keeps $CC/$CXX consistent with the compiler the shell's own stdenv
  # already resolves to, on every platform, not just Darwin.

  ccacheShellHook = pkgs.lib.optionalString enableCcache ''
    export CC="${cachedClang}/bin/clang"
    export CXX="${cachedClangxx}/bin/clang++"
    # NIX_DEVSHELLS_CCACHE_DIR is a plain shell env var, checked at `nix
    # develop`/shellHook time -- not baked into any Nix expression -- so it
    # can be set once (e.g. in your shell profile or a project's .envrc) to
    # control the cache location for every devshell built from this helper,
    # with no Nix re-evaluation needed. Unset, it defaults to one shared
    # path, so devshells sharing this helper (e.g. stdexec and Sendosio)
    # share cache entries out of the box -- override per-project via a
    # project-local .envrc if you'd rather keep them isolated.
    export CCACHE_DIR="''${NIX_DEVSHELLS_CCACHE_DIR:-$HOME/.cache/nix-devshells-ccache}"
    # ccache's precedence is env var > ccache.conf (in CCACHE_DIR) > its own
    # built-in default (5G). We deliberately do NOT export CCACHE_MAXSIZE
    # with a fallback default here -- doing so would win over any size
    # you've persisted in CCACHE_DIR/ccache.conf (e.g. via home-manager, or
    # a one-time `ccache --max-size=...`) every single time you enter any
    # devshell built from this helper, silently undoing it. Only set it if
    # you explicitly want a one-off override for this shell session:
    if [ -n "''${NIX_DEVSHELLS_CCACHE_MAX_SIZE:-}" ]; then
      export CCACHE_MAXSIZE="$NIX_DEVSHELLS_CCACHE_MAX_SIZE"
    fi
  '';
in
pkgs.mkShell.override { stdenv = llvmPackages.libcxxStdenv; } {
  packages = [ clang-tools ] ++ extraPackages ++ pkgs.lib.optional enableCcache pkgs.ccache;

  shellHook = ''
    export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -B${llvmPackages.libcxx}/lib"
    # clang-scan-deps (invoked directly by CMake/Ninja to scan C++20/23
    # module dependencies, e.g. libc++'s std.cppm for `import std;`) bypasses
    # cc-wrapper's flag injection entirely. Unlike clang++, nixpkgs does not
    # currently wrap clang-scan-deps anywhere -- not even the copy bundled in
    # `clang-tools` -- so it never sees the -isystem paths the real wrapped
    # clang++ gets by default, and fails to find libc++ headers (e.g.
    # 'text_encoding' file not found) even though a normal compile with the
    # identical flags succeeds. This is a known, still-open nixpkgs bug:
    # https://github.com/NixOS/nixpkgs/issues/452260
    # https://github.com/NixOS/nixpkgs/pull/514323
    # CPLUS_INCLUDE_PATH is a standard Clang/GCC search-path env var that
    # clang-scan-deps *does* honor, since it doesn't depend on the wrapper.
    export CPLUS_INCLUDE_PATH="${pkgs.lib.getDev llvmPackages.libcxx}/include/c++/v1''${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
  ''
  + builtins.readFile ./debugserver-shellhook.sh
  + ccacheShellHook
  + extraShellHook;
}
