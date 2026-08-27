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
    exec ${pkgs.ccache}/bin/ccache ${llvmPackages.clang}/bin/clang "$@"
  '';
  cachedClangxx = pkgs.writeShellScriptBin "clang++" ''
    exec ${pkgs.ccache}/bin/ccache ${llvmPackages.clang}/bin/clang++ "$@"
  '';

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
  ''
  + builtins.readFile ./debugserver-shellhook.sh
  + ccacheShellHook
  + extraShellHook;
}
