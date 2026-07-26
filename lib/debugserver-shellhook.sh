# lldb on macOS needs Apple's signed debugserver to actually
# launch/attach to processes; Nix can't ship one (Apple doesn't
# allow redistributing it), so we borrow it from the system's
# Xcode installation -- either the standalone Command Line Tools
# or a full Xcode.app. See:
# https://github.com/NixOS/nixpkgs/issues/252838
#
# NOTE: `xcrun --find debugserver` doesn't work even when
# debugserver is present -- it lives inside LLDB.framework's
# Resources dir, which isn't one of the locations `xcrun --find`
# searches. So we check the known, stable relative paths directly
# instead of relying on xcrun to locate it.
DEV_DIR="$(DEVELOPER_DIR= /usr/bin/xcode-select -p 2>/dev/null)"
if [ -n "$DEV_DIR" ] && [ -d "$DEV_DIR" ]; then
  CLT_DEBUGSERVER="$DEV_DIR/Library/PrivateFrameworks/LLDB.framework/Versions/A/Resources/debugserver"
  XCODE_DEBUGSERVER="$DEV_DIR/../SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver"

  if [ -x "$CLT_DEBUGSERVER" ]; then
    export LLDB_DEBUGSERVER_PATH="$CLT_DEBUGSERVER"
  elif [ -x "$XCODE_DEBUGSERVER" ]; then
    export LLDB_DEBUGSERVER_PATH="$XCODE_DEBUGSERVER"
  else
    cat >&2 <<'EOF'

warning: Found a developer directory, but no debugserver alongside it.
         `lldb` will start, but `run`/`process launch` will fail.
         Try reinstalling the Command Line Tools:
             xcode-select --install

EOF
  fi
else
  cat >&2 <<'EOF'

warning: Xcode Command Line Tools (or Xcode.app) not found on this machine.
         `lldb` will start, but `run`/`process launch` will fail with
         something like:
             error: executable doesn't exist: '(empty)'

         To fix this, install the Command Line Tools:
             xcode-select --install
         then re-enter this shell (`exit` and `nix develop` again).

EOF
fi
