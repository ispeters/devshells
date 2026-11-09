"""Run rows of stdexec's GitHub Actions CI matrix locally, in Docker.

Reads the workflow straight from the stdexec checkout, so the matrix, images,
compiler flags and build scripts are whatever the workflow currently says.
Each selected row runs as a fresh container from the row's image, replaying
the job's steps the way GitHub Actions would, with a small set of documented
local substitutions:

  * actions/checkout       -> the working tree (tracked files plus untracked,
                              non-ignored files, including uncommitted edits)
  * actions/cache{,/restore,/save}
                           -> a named Docker volume per (key, platform); a
                              marker file records a completed save
  * credentials/artifacts  -> skipped (configure-aws-credentials,
                              upload-artifact)
  * sccache                -> local-disk cache in a Docker volume; the S3
                              bucket and distributed-compile settings are
                              removed (see local-overrides.sh)
  * `cmake --build -j N`   -> N capped to what the VM can hold in memory
  * ctest / valgrind       -> skipped unless --test is given
  * stack size limit       -> 32 MiB instead of Docker's 8 MiB (--stack-mib);
                              see DEFAULT_STACK_MIB
  * test timeouts          -> multiplied for rows emulated on another
                              architecture (--emulated-timeout-scale); see
                              DEFAULT_EMULATED_TIMEOUT_SCALE

Rows run on linux/arm64 (native under Colima) unless the row's steps need
amd64 (see _AMD64_ONLY_RE) or the image has no arm64 variant.

To run something other than CI's own build, such as one example:

  * --target T             -> every `cmake --build` builds only T (repeatable),
                              instead of the targets the step names
  * --then CMD             -> after the job, runs CMD in the configured tree
                              (THEN_DIR) as the build step's user, with its
                              environment; CMD's output is shown even without
                              --verbose

e.g. stdexec-ci "gcc 14, Release, ASAN" --target example.hello_world \
         --then build/examples/example.hello_world
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import io
import json
import math
import os
import re
import shlex
import subprocess
import sys
import tarfile
import time
from pathlib import Path
from typing import Any

import yaml

# --------------------------------------------------------------------------
# GitHub Actions expression evaluation (the subset stdexec's workflows use)
# --------------------------------------------------------------------------

_TOKEN_RE = re.compile(
    r"""\s*(?:
        (?P<str>'(?:[^']|'')*')
      | (?P<num>-?\d+(?:\.\d+)?)
      | (?P<op>&&|\|\||==|!=|<=|>=|<|>|!|\(|\)|,)
      | (?P<ident>[A-Za-z_][A-Za-z0-9_\-]*(?:\.[A-Za-z_][A-Za-z0-9_\-]*)*)
    )""",
    re.VERBOSE,
)


class ExprError(Exception):
    pass


def _tokenize(src: str) -> list[tuple[str, str]]:
    pos, out = 0, []
    src = src.rstrip()
    while pos < len(src):
        m = _TOKEN_RE.match(src, pos)
        if not m or m.end() == pos:
            raise ExprError(f"cannot parse expression at {src[pos:]!r} in {src!r}")
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
        pos = m.end()
    return out


def _to_number(v: Any) -> float:
    if v is None:
        return 0.0
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        s = v.strip()
        if s == "":
            return 0.0
        try:
            return float(s)
        except ValueError:
            return math.nan
    return math.nan


def _truthy(v: Any) -> bool:
    if v is None or v is False:
        return False
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return v != 0 and not math.isnan(v)
    if isinstance(v, str):
        return v != ""
    return True


def _equal(a: Any, b: Any) -> bool:
    # GitHub: same type -> direct comparison (strings case-insensitively);
    # different types -> both coerced to numbers.
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if type(a) is type(b) and not isinstance(a, float):
        return a == b
    return _to_number(a) == _to_number(b)


def to_string(v: Any) -> str:
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


class _Parser:
    def __init__(self, src: str, ctx: dict[str, Any]):
        self.src = src
        self.toks = _tokenize(src)
        self.i = 0
        self.ctx = ctx

    def peek(self) -> tuple[str, str] | None:
        return self.toks[self.i] if self.i < len(self.toks) else None

    def take(self, value: str | None = None) -> tuple[str, str]:
        tok = self.peek()
        if tok is None or (value is not None and tok[1] != value):
            raise ExprError(f"expected {value or 'token'} in {self.src!r}")
        self.i += 1
        return tok

    def parse(self) -> Any:
        v = self.or_()
        if self.peek() is not None:
            raise ExprError(f"trailing tokens in {self.src!r}")
        return v

    def or_(self) -> Any:
        v = self.and_()
        while self.peek() == ("op", "||"):
            self.take()
            rhs = self.and_()
            v = v if _truthy(v) else rhs
        return v

    def and_(self) -> Any:
        v = self.cmp()
        while self.peek() == ("op", "&&"):
            self.take()
            rhs = self.cmp()
            v = rhs if _truthy(v) else v
        return v

    def cmp(self) -> Any:
        v = self.unary()
        while self.peek() and self.peek()[1] in ("==", "!=", "<", ">", "<=", ">="):
            op = self.take()[1]
            rhs = self.unary()
            if op == "==":
                v = _equal(v, rhs)
            elif op == "!=":
                v = not _equal(v, rhs)
            else:
                a, b = _to_number(v), _to_number(rhs)
                v = {"<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[op]
        return v

    def unary(self) -> Any:
        if self.peek() == ("op", "!"):
            self.take()
            return not _truthy(self.unary())
        return self.primary()

    def primary(self) -> Any:
        tok = self.take()
        kind, text = tok
        if kind == "op" and text == "(":
            v = self.or_()
            self.take(")")
            return v
        if kind == "str":
            return text[1:-1].replace("''", "'")
        if kind == "num":
            return float(text)
        if kind == "ident":
            if text in ("true", "false"):
                return text == "true"
            if text == "null":
                return None
            if self.peek() == ("op", "("):
                return self.call(text)
            return self.lookup(text)
        raise ExprError(f"unexpected {text!r} in {self.src!r}")

    def call(self, name: str) -> Any:
        self.take("(")
        args = []
        if self.peek() != ("op", ")"):
            args.append(self.or_())
            while self.peek() == ("op", ","):
                self.take()
                args.append(self.or_())
        self.take(")")
        fn = name.lower()
        if fn == "contains":
            hay, needle = args
            if isinstance(hay, list):
                return any(_equal(x, needle) for x in hay)
            return to_string(needle).lower() in to_string(hay).lower()
        if fn == "startswith":
            return to_string(args[0]).lower().startswith(to_string(args[1]).lower())
        if fn == "endswith":
            return to_string(args[0]).lower().endswith(to_string(args[1]).lower())
        if fn in ("success", "always"):
            return True
        if fn in ("failure", "cancelled"):
            return False
        if fn == "format":
            fmt = to_string(args[0])
            return re.sub(r"\{(\d+)\}", lambda m: to_string(args[1 + int(m.group(1))]), fmt)
        raise ExprError(f"unsupported function {name}() in {self.src!r}")

    def lookup(self, path: str) -> Any:
        cur: Any = self.ctx
        for part in path.split("."):
            if isinstance(cur, dict):
                cur = cur.get(part)
            else:
                return None
        return cur


def evaluate(expr: str, ctx: dict[str, Any]) -> Any:
    expr = expr.strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", expr, re.S)
    if m:
        expr = m.group(1)
    return _Parser(expr, ctx).parse()


_TEMPLATE_RE = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def render(text: Any, ctx: dict[str, Any]) -> str:
    if not isinstance(text, str):
        return to_string(text)
    return _TEMPLATE_RE.sub(lambda m: to_string(_Parser(m.group(1), ctx).parse()), text)


def condition(step_if: Any, ctx: dict[str, Any]) -> bool:
    if step_if is None:
        return True
    if isinstance(step_if, bool):
        return step_if
    return _truthy(evaluate(str(step_if), ctx))


# --------------------------------------------------------------------------
# Docker helpers
# --------------------------------------------------------------------------

DRY_RUN = False


def docker(*args: str, check: bool = True, capture: bool = False,
           stdin: bytes | None = None, quiet: bool = False) -> subprocess.CompletedProcess:
    cmd = ["docker", *args]
    if DRY_RUN:
        print("+ " + shlex.join(cmd))
        return subprocess.CompletedProcess(cmd, 0, b"", b"")
    return subprocess.run(
        cmd,
        check=check,
        input=stdin,
        stdout=subprocess.PIPE if capture or quiet else None,
        stderr=subprocess.PIPE if capture or quiet else None,
    )


_manifest_cache: dict[str, set[str]] = {}


def image_architectures(image: str) -> set[str]:
    if DRY_RUN:
        return {"amd64", "arm64"}
    if image not in _manifest_cache:
        r = docker("manifest", "inspect", image, check=False, capture=True)
        archs: set[str] = set()
        if r.returncode == 0:
            data = json.loads(r.stdout)
            for m in data.get("manifests", []):
                p = m.get("platform", {})
                if p.get("os") == "linux" and p.get("architecture") not in (None, "unknown"):
                    archs.add(p["architecture"])
            if not archs and "architecture" in data:  # single-arch manifest
                archs.add(data["architecture"])
        if not archs:
            # Unknown (offline, or a locally built image): trust whatever is
            # available locally.
            r = docker("image", "inspect", "--format", "{{.Architecture}}", image,
                       check=False, capture=True)
            if r.returncode == 0:
                archs.add(r.stdout.decode().strip())
        _manifest_cache[image] = archs
    return _manifest_cache[image]


def volume_exists(name: str) -> bool:
    if DRY_RUN:
        return False
    return docker("volume", "inspect", name, check=False, quiet=True).returncode == 0


def cache_volume_complete(volume: str, image: str, platform: str) -> bool:
    if not volume_exists(volume):
        return False
    r = docker("run", "--rm", "--platform", platform, "--entrypoint", "test",
               "-v", f"{volume}:/v:ro", image, "-f", f"/v/{CACHE_MARKER}",
               check=False, quiet=True)
    return r.returncode == 0


# --------------------------------------------------------------------------
# Planning: turn (workflow job, matrix row) into a container recipe
# --------------------------------------------------------------------------

BUNDLE = "/opt/stdexec-ci"
CACHE_MARKER = ".stdexec-ci-cache-complete"

# The containers' stack size limit, which glibc also uses as the default size
# of new threads' stacks.  Docker's default of 8 MiB is too small for some
# tests that pass in CI: under GCC 14 with ASAN at -O3, "repro for
# NVIDIA/stdexec#2047 no stack overflow" needs 12 MiB on a thread-pool thread.
# CI's own limit isn't known; this only needs to stop such tests failing
# locally, and the limit reserves address space rather than memory.
DEFAULT_STACK_MIB = 32

# Rows emulated on another architecture (amd64 under Rosetta on an arm64 VM)
# run their tests several times slower than CI does, and the slowest tests,
# such as the Relacy model checks, then exceed their TIMEOUT properties.
# ctest can only override the default timeout (--timeout), not a test's own
# TIMEOUT property, so the ctest shim multiplies both, rewriting the TIMEOUT
# properties in the build tree's generated test files.
DEFAULT_EMULATED_TIMEOUT_SCALE = 4
WORKSPACE = "/__w/stdexec/stdexec"

SKIPPED_ACTIONS = {
    "aws-actions/configure-aws-credentials": "no AWS credentials locally",
    "actions/upload-artifact": "artifacts are not uploaded locally",
}

# Step env vars that only make sense on NVIDIA's CI (remote cache, distributed
# compile).  local-overrides.sh also unsets these, in case the image's own
# environment sets them.
_DROPPED_ENV_RE = re.compile(r"^(AWS_.*|SCCACHE_(BUCKET|REGION|ENDPOINT|S3_.*|DIST_.*|GCS_.*|REDIS.*))$")

# Content of a row's rendered steps that can only work on amd64:
#   -m32                        : 32-bit x86; there is no arm64 equivalent.
#   LLVM_TARGETS_TO_BUILD=X86   : a toolchain built from source with only the
#                                 X86 backend can't target an arm64 host.
_AMD64_ONLY_RE = re.compile(r"(?:^|[\s'\"=])-m32(?:$|[\s'\"])|LLVM_TARGETS_TO_BUILD=X86\b", re.M)


@dataclasses.dataclass
class Op:
    kind: str  # "checkout" | "run" | "mark-cache" | "skip"
    name: str
    data: dict[str, Any] = dataclasses.field(default_factory=dict)


@dataclasses.dataclass
class Plan:
    row: dict[str, Any]
    name: str
    image: str
    platform: str
    platform_reason: str
    options: list[str]
    ops: list[Op]
    mounts: list[tuple[str, str]]  # (volume, path)
    allow_failure: bool


def _slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", s).strip("-").lower()


def _shell_argv(template: str) -> list[str]:
    t = template.strip()
    if t == "bash":
        t = "bash --noprofile --norc -eo pipefail {0}"
    elif t == "sh":
        t = "sh -e {0}"
    elif t in ("pwsh", "powershell", "cmd", "python"):
        raise ExprError(f"shell {t!r} isn't supported")
    elif "{0}" not in t:
        raise ExprError(f"custom shell {t!r} has no {{0}} placeholder")
    return shlex.split(t)


def _job_name(job: dict[str, Any], row: dict[str, Any]) -> str:
    raw = job.get("name") or row.get("name") or json.dumps(row, sort_keys=True)
    return render(raw, {"matrix": row})


def matrix_rows(job: dict[str, Any]) -> list[dict[str, Any]]:
    strategy = job.get("strategy") or {}
    matrix = strategy.get("matrix")
    if matrix is None:
        return [{}]
    extra = set(matrix) - {"include"}
    if extra:
        raise ExprError(f"only `matrix: include:` lists are supported (found {sorted(extra)})")
    return list(matrix["include"])


def make_plan(job_id: str, job: dict[str, Any], row: dict[str, Any], *,
              platform_choice: str, probe_caches: bool) -> Plan:
    name = _job_name(job, row)
    ctx: dict[str, Any] = {
        "matrix": row,
        "github": {
            "repository_owner": "local",
            "repository": "local/stdexec",
            "workspace": WORKSPACE,
            "event_name": "push",
            "run_id": "local",
            "run_attempt": "1",
            "job": job_id,
        },
        "runner": {"os": "Linux", "arch": "ARM64", "temp": "/tmp", "tool_cache": "/opt/hostedtoolcache"},
        "steps": {},
        "env": {},
    }

    container = job.get("container")
    if not container:
        raise ExprError(f"job {job_id!r} has no `container:`; only container jobs can run locally")
    if isinstance(container, str):
        container = {"image": container}
    image = render(container["image"], ctx)
    options = shlex.split(render(container.get("options", ""), ctx))
    # The container's user is chosen with -u in options; docker create takes
    # it the same way.

    defaults = (job.get("defaults") or {}).get("run") or {}
    default_shell = defaults.get("shell", "bash -e {0}")
    default_wd = defaults.get("working-directory", WORKSPACE)

    allow_failure = _truthy(evaluate(str(job["continue-on-error"]), ctx)) if "continue-on-error" in job else False

    def build_ops(platform: str, cache_hits: dict[str, bool]) -> tuple[list[Op], list[tuple[str, str]]]:
        ctx["steps"] = {}
        ctx["runner"]["arch"] = "X64" if platform.endswith("amd64") else "ARM64"
        ops: list[Op] = []
        mounts: list[tuple[str, str]] = []
        pending_saves: list[Op] = []
        for step in job.get("steps", []):
            sname = render(step.get("name") or step.get("uses") or step.get("run", "").split("\n")[0], ctx)
            if not condition(step.get("if"), ctx):
                ops.append(Op("skip", sname, {"why": "`if:` is false"}))
                continue
            sid = step.get("id")
            if "uses" in step:
                action = step["uses"].split("@")[0]
                with_ = {k: render(v, ctx) for k, v in (step.get("with") or {}).items()}
                if action == "actions/checkout":
                    ops.append(Op("checkout", sname, {"path": with_.get("path", "")}))
                elif action in ("actions/cache", "actions/cache/restore"):
                    path, key = with_["path"].strip(), with_["key"]
                    if "\n" in path:
                        raise ExprError(f"step {sname!r}: multi-path caches aren't supported")
                    vol = "stdexec-ci-cache-" + hashlib.sha256(f"{key}\0{platform}".encode()).hexdigest()[:16]
                    mounts.append((vol, path))
                    hit = cache_hits.get(vol, False)
                    if sid:
                        ctx["steps"][sid] = {"outputs": {"cache-hit": "true" if hit else "false",
                                                         "cache-primary-key": key,
                                                         "cache-matched-key": key if hit else ""},
                                             "outcome": "success", "conclusion": "success"}
                    ops.append(Op("skip", sname, {"why": f"cache {'hit' if hit else 'miss'}: volume {vol}"}))
                    if action == "actions/cache" and not hit:
                        pending_saves.append(Op("mark-cache", f"Post {sname}", {"path": path}))
                elif action == "actions/cache/save":
                    ops.append(Op("mark-cache", sname, {"path": with_["path"].strip()}))
                elif action in SKIPPED_ACTIONS:
                    ops.append(Op("skip", sname, {"why": SKIPPED_ACTIONS[action]}))
                else:
                    raise ExprError(f"step {sname!r} uses unsupported action {step['uses']!r}")
                continue
            script = render(step["run"], ctx)
            env = {k: render(v, ctx) for k, v in (step.get("env") or {}).items()}
            env = {k: v for k, v in env.items() if not _DROPPED_ENV_RE.match(k)}
            ops.append(Op("run", sname, {
                "script": script,
                "argv": _shell_argv(step.get("shell", default_shell)),
                "wd": render(step.get("working-directory", default_wd), ctx),
                "env": env,
            }))
            if sid:
                ctx["steps"][sid] = {"outputs": {}, "outcome": "success", "conclusion": "success"}
        ops.extend(pending_saves)
        return ops, mounts

    # Pass 1: decide the platform from what the row would run on a cache miss
    # (the miss path is the superset: it includes any from-source toolchain
    # build).
    ops, _ = build_ops("linux/amd64", {})
    rendered = "\n".join(
        o.data["script"] + "\n" + "\n".join(f"{k}={v}" for k, v in o.data["env"].items())
        for o in ops if o.kind == "run"
    )
    archs = image_architectures(image) if platform_choice == "auto" else set()
    if platform_choice == "amd64":
        platform, reason = "linux/amd64", "--platform amd64"
    elif _AMD64_ONLY_RE.search(rendered):
        what = _AMD64_ONLY_RE.search(rendered).group(0).strip(" '\"=")
        platform, reason = "linux/amd64", f"row uses {what}"
    elif "arm64" in archs:
        platform, reason = "linux/arm64", "native"
    else:
        platform, reason = "linux/amd64", f"image has no arm64 variant ({', '.join(sorted(archs)) or 'unknown'})"

    # Pass 2: with the platform fixed, probe the cache volumes and re-plan.
    _, mounts = build_ops(platform, {})
    hits = {}
    if probe_caches:
        for vol, _path in mounts:
            hits[vol] = cache_volume_complete(vol, image, platform)
    ops, mounts = build_ops(platform, hits)
    return Plan(row, name, image, platform, reason, options, ops, mounts, allow_failure)


# Where --then commands run: the build step copies the checkout to the
# container user's home as `stdexec` and configures it in `build/` there.
THEN_DIR = "~/stdexec"
THEN_STEP_NAME = "--then command"


def build_op_index(plan: Plan) -> int:
    """The index of the job's build step, taken to be its last `run:` step;
    the steps before it set up the row's environment."""
    for i in range(len(plan.ops) - 1, -1, -1):
        if plan.ops[i].kind == "run":
            return i
    raise ExprError(f"{plan.name}: the job has no `run:` step")


def add_then(plan: Plan, command: str) -> None:
    """Append a step that runs command in THEN_DIR the way the build step
    runs: same shell (and so the same user), working directory and step
    environment, with the image's login profile sourced as the build step
    does."""
    build = plan.ops[build_op_index(plan)]
    script = f"set -e\nsource /etc/profile\ncd {THEN_DIR}\n{command}\n"
    plan.ops.append(Op("run", THEN_STEP_NAME, {**build.data, "script": script}))


# --------------------------------------------------------------------------
# Bundle: the files copied into the container before it starts
# --------------------------------------------------------------------------

LOCAL_OVERRIDES = r"""# Sourced by the driver, and again after every `source /etc/profile` in a
# step, so it wins over anything the image's profile scripts set.
case ":${PATH}:" in *":/opt/stdexec-ci/shims:"*) ;; *) export PATH="/opt/stdexec-ci/shims:${PATH}" ;; esac
for __v in $(compgen -e); do
  case "${__v}" in
    AWS_*|SCCACHE_BUCKET|SCCACHE_REGION|SCCACHE_ENDPOINT|SCCACHE_S3_*|SCCACHE_DIST_*|SCCACHE_GCS_*|SCCACHE_REDIS*)
      unset "${__v}" ;;
  esac
done
unset __v
# Local-disk sccache, one directory per user so root-run and coder-run jobs
# don't fight over ownership.  SCCACHE_CONF points at an empty file so no
# config baked into the image re-enables a remote cache.
export SCCACHE_CONF=/opt/stdexec-ci/sccache.conf
export SCCACHE_DIR="/var/cache/stdexec-ci/sccache/$(id -un)"
export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-40G}"
export SCCACHE_NO_DIST_COMPILE=1
export CPM_SOURCE_CACHE="/var/cache/stdexec-ci/cpm/$(id -un)"
mkdir -p "${SCCACHE_DIR}" "${CPM_SOURCE_CACHE}" 2>/dev/null || true
"""

SHIM_LIB = r"""# Finds the next executable called $1 on PATH after the shims directory.
stdexec_ci_real() {
  local dir IFS=:
  for dir in ${PATH}; do
    [[ "${dir}" == /opt/stdexec-ci/shims ]] && continue
    if [[ -x "${dir}/$1" ]]; then printf '%s\n' "${dir}/$1"; return 0; fi
  done
  echo "stdexec-ci: $1 not found on PATH" >&2
  return 127
}
"""

# The shims run as `bash -p` so that they don't source $BASH_ENV: the images
# set it to a script that re-exports variables a step may have deliberately
# unset (e.g. PYTHONSAFEPATH), and a shim must pass its environment through
# to the real tool unchanged.
SHIMS = {
    # NVIDIA CI's distributed-compile setup authenticates with GitHub's OIDC
    # endpoint; there is nothing to set up locally.  (The step still runs its
    # `curl` command substitutions, which print harmless errors.)
    "devcontainer-utils-init-sccache-dist": r"""#!/bin/bash -p
cat >/dev/null
echo "stdexec-ci: skipped devcontainer-utils-init-sccache-dist (local-disk sccache instead)" >&2
""",
    "ctest": r"""#!/bin/bash -p
. /opt/stdexec-ci/shim-lib.sh
if [[ "${STDEXEC_CI_BUILD_ONLY:-0}" == 1 ]]; then
  echo "stdexec-ci: build-only run; skipped: ctest $*" >&2
  exit 0
fi
scale="${STDEXEC_CI_TIMEOUT_SCALE:-1}"
if [[ "${scale}" == 1 ]]; then
  exec "$(stdexec_ci_real ctest)" "$@"
fi
# Multiply --timeout, and the TIMEOUT properties in the generated test files
# of the test directory (--test-dir, or the current directory).
args=() dir=.
while (( $# )); do
  case "$1" in
    --timeout)
      if [[ $# -ge 2 ]]; then args+=(--timeout "$(( $2 * scale ))"); shift 2
      else args+=("$1"); shift; fi ;;
    --timeout=*) args+=("--timeout=$(( ${1#--timeout=} * scale ))"); shift ;;
    --test-dir)
      if [[ $# -ge 2 ]]; then dir="$2"; args+=("$1" "$2"); shift 2
      else args+=("$1"); shift; fi ;;
    --test-dir=*) dir="${1#--test-dir=}"; args+=("$1"); shift ;;
    *) args+=("$1"); shift ;;
  esac
done
find "${dir}" -type f \( -name CTestTestfile.cmake -o -name '*_tests*.cmake' \) \
  -exec perl /opt/stdexec-ci/scale-timeouts.pl "${scale}" {} +
echo "stdexec-ci: emulated row; test timeouts multiplied by ${scale}" >&2
exec "$(stdexec_ci_real ctest)" "${args[@]}"
""",
    "valgrind": r"""#!/bin/bash -p
. /opt/stdexec-ci/shim-lib.sh
if [[ "${STDEXEC_CI_BUILD_ONLY:-0}" == 1 ]]; then
  echo "stdexec-ci: build-only run; skipped: valgrind $*" >&2
  exit 0
fi
exec "$(stdexec_ci_real valgrind)" "$@"
""",
    # CI builds with -j 512 against a distributed-compile farm.  Locally that
    # just exhausts the VM's memory, so cap the parallelism of every
    # `cmake --build` (and supply the cap when none is given, since ninja's
    # default of nproc+2 can also be too many for heavy template TUs).
    #
    # With --target, STDEXEC_CI_TARGETS replaces the targets of every
    # `cmake --build`, including builds of specific targets such as the
    # header-set check, which then just rebuild the requested targets.
    "cmake": r"""#!/bin/bash -p
. /opt/stdexec-ci/shim-lib.sh
real="$(stdexec_ci_real cmake)" || exit 127
is_build=0
for a in "$@"; do [[ "$a" == --build ]] && is_build=1; done
if (( ! is_build )); then exec "${real}" "$@"; fi
cap="${STDEXEC_CI_JOBS:-auto}"
if [[ "${cap}" == auto ]]; then
  mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  by_mem=$(( mem_kib / (2 * 1024 * 1024) ))   # ~2 GiB per compile job
  cap=$(nproc)
  (( by_mem < cap )) && cap=${by_mem}
  (( cap < 1 )) && cap=1
fi
targets="${STDEXEC_CI_TARGETS:-}"
args=() saw_j=0
while (( $# )); do
  case "$1" in
    -j|--parallel)
      saw_j=1
      if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
        n=$2; shift 2
        (( n > cap )) && n=${cap}
        args+=(-j "${n}")
      else
        shift; args+=(-j "${cap}")
      fi ;;
    -j[0-9]*|--parallel=[0-9]*)
      saw_j=1
      n="${1#-j}"; n="${n#--parallel=}"; shift
      (( n > cap )) && n=${cap}
      args+=(-j "${n}") ;;
    -t|--target)
      # --target takes one or more names.
      if [[ -n "${targets}" ]]; then
        shift
        while (( $# )) && [[ "$1" != -* ]]; do shift; done
      else
        args+=("$1"); shift
      fi ;;
    --target=*)
      [[ -n "${targets}" ]] || args+=("$1")
      shift ;;
    --) args+=("$@"); break ;;
    *) args+=("$1"); shift ;;
  esac
done
extra=()
(( saw_j )) || extra+=(-j "${cap}")
if [[ -n "${targets}" ]]; then
  read -ra target_list <<< "${targets}"
  extra+=(--target "${target_list[@]}")
fi
if (( ${#extra[@]} )); then
  # Options after `--` go to the native tool, so insert ours before it.
  out=() inserted=0
  for a in "${args[@]}"; do
    if [[ "$a" == -- && ${inserted} == 0 ]]; then out+=("${extra[@]}"); inserted=1; fi
    out+=("$a")
  done
  (( inserted )) || out+=("${extra[@]}")
  args=("${out[@]}")
fi
echo "stdexec-ci: cmake ${args[*]}  (parallelism capped at ${cap})" >&2
exec "${real}" "${args[@]}"
""",
}


# Multiplies the TIMEOUT properties in ctest's generated test files, in place.
# CMake writes them as `TIMEOUT "120"`, Catch2's test discovery as
# `TIMEOUT 30`.  A marker line keeps a file that the build hasn't regenerated
# from being multiplied twice.
SCALE_TIMEOUTS = r"""use strict;
my $scale = shift @ARGV;
my $marker = "# stdexec-ci: TIMEOUT properties multiplied\n";
for my $file (@ARGV) {
  open(my $in, "<", $file) or die "$file: $!";
  my $text = do { local $/; <$in> };
  close($in);
  next if index($text, $marker) == 0;
  $text =~ s/\bTIMEOUT(\s+)("?)(\d+(?:\.\d+)?)\2/"TIMEOUT$1$2" . ($3 * $scale) . $2/ge;
  open(my $out, ">", $file) or die "$file: $!";
  print $out $marker, $text;
  close($out);
}
"""


def _inject_overrides(script: str) -> str:
    # Re-apply the local overrides after the step sources the image's login
    # profile, which may re-export the CI-only settings.
    return re.sub(
        r"^(\s*(?:source|\.)\s+/etc/profile\b[^\n]*?)(;?\s*)$",
        lambda m: f"{m.group(1)}; . {BUNDLE}/local-overrides.sh{m.group(2) if m.group(2).strip() else ''}",
        script,
        flags=re.M,
    )


def _env_file(env: dict[str, str]) -> str:
    return "".join(f"export {k}={shlex.quote(v)}\n" for k, v in env.items())


DRIVER_HEAD = r"""#!/bin/bash
# Generated by stdexec-ci.  Replays one GitHub Actions job in this container.
set -euo pipefail
B=/opt/stdexec-ci
mkdir -p /tmp/stdexec-ci
: > /tmp/stdexec-ci/github_env
chmod 0666 /tmp/stdexec-ci/github_env
export CI=true
export GITHUB_ENV=/tmp/stdexec-ci/github_env
export GITHUB_WORKSPACE=__WORKSPACE__
export RUNNER_OS=Linux RUNNER_TEMP=/tmp
mkdir -p "${GITHUB_WORKSPACE}" /var/cache/stdexec-ci/sccache /var/cache/stdexec-ci/cpm
chmod 1777 /var/cache/stdexec-ci/sccache /var/cache/stdexec-ci/cpm
. "$B/local-overrides.sh"

load_github_env() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*'<<' ]]; then
      echo "stdexec-ci: multi-line GITHUB_ENV entries aren't supported: ${line}" >&2
      return 1
    fi
    [[ "${line}" == *=* ]] && export "${line%%=*}=${line#*=}"
  done < "${GITHUB_ENV}"
}

banner() { printf '\n\033[1;34m==== stdexec-ci: %s\033[0m\n' "$*"; }

run_step() {  # run_step <n> <working-dir> <argv...with {0}>
  local n="$1" wd="$2"; shift 2
  local script="/tmp/stdexec-ci/step-${n}.sh" argv=() a
  cp "$B/steps/${n}.sh" "${script}"
  chmod 0755 "${script}"
  for a in "$@"; do argv+=("${a//\{0\}/${script}}"); done
  (
    load_github_env
    . "$B/steps/${n}.env"
    . "$B/local-overrides.sh"
    mkdir -p "${wd}"
    cd "${wd}"
    "${argv[@]}"
  )
}
"""


def build_bundle(plan: Plan, source_tar: bytes) -> bytes:
    files: dict[str, tuple[bytes, int]] = {}

    def add(path: str, text: str | bytes, mode: int = 0o644) -> None:
        files[path] = (text.encode() if isinstance(text, str) else text, mode)

    add("local-overrides.sh", LOCAL_OVERRIDES)
    add("shim-lib.sh", SHIM_LIB)
    add("scale-timeouts.pl", SCALE_TIMEOUTS)
    add("sccache.conf", "")
    for shim, text in SHIMS.items():
        add(f"shims/{shim}", text, 0o755)
    add("source.tar", source_tar)

    driver = [DRIVER_HEAD.replace("__WORKSPACE__", WORKSPACE)]
    # Cache mount points must be writable by whoever writes them in CI; a
    # fresh volume is root-owned.  Give it to the owner of the enclosing home
    # directory, if any.
    for _vol, path in plan.mounts:
        m = re.match(r"^/home/([^/]+)/", path)
        if m:
            driver.append(f"id -u {shlex.quote(m.group(1))} >/dev/null 2>&1 && "
                          f"chown {shlex.quote(m.group(1))}: {shlex.quote(path)}\n")
    n = 0
    for op in plan.ops:
        driver.append(f"banner {shlex.quote(op.name)}\n")
        if op.kind == "skip":
            driver.append(f"echo {shlex.quote('skipped: ' + op.data['why'])}\n")
        elif op.kind == "checkout":
            dest = f'"${{GITHUB_WORKSPACE}}"/{shlex.quote(op.data["path"])}' if op.data["path"] else '"${GITHUB_WORKSPACE}"'
            driver.append(f"mkdir -p {dest} && tar -C {dest} -xf \"$B/source.tar\"\n")
        elif op.kind == "mark-cache":
            path = shlex.quote(op.data["path"])
            driver.append(f"test -d {path} && touch {path}/{CACHE_MARKER}\n")
        elif op.kind == "run":
            n += 1
            add(f"steps/{n}.sh", _inject_overrides(op.data["script"]), 0o755)
            add(f"steps/{n}.env", _env_file(op.data["env"]))
            argv = " ".join(shlex.quote(a) for a in op.data["argv"])
            driver.append(f"run_step {n} {shlex.quote(op.data['wd'])} {argv}\n")
    driver.append("banner 'job finished'\n")
    add("driver.sh", "".join(driver), 0o755)

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        root = tarfile.TarInfo(BUNDLE.lstrip("/"))
        root.type, root.mode = tarfile.DIRTYPE, 0o755
        tar.addfile(root)
        for d in ("shims", "steps"):
            ti = tarfile.TarInfo(f"{BUNDLE.lstrip('/')}/{d}")
            ti.type, ti.mode = tarfile.DIRTYPE, 0o755
            tar.addfile(ti)
        for path, (data, mode) in sorted(files.items()):
            ti = tarfile.TarInfo(f"{BUNDLE.lstrip('/')}/{path}")
            ti.size, ti.mode, ti.mtime = len(data), mode, int(time.time())
            tar.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def source_tarball(repo: Path) -> bytes:
    """Tracked and untracked-but-not-ignored files, as they are on disk."""
    out = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True, capture_output=True,
    ).stdout
    names = sorted({n for n in out.decode().split("\0") if n})
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for name in names:
            p = repo / name
            if not p.exists() and not p.is_symlink():
                continue  # deleted in the working tree
            ti = tar.gettarinfo(str(p), arcname=name)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            if ti.isfile():
                with open(p, "rb") as f:
                    tar.addfile(ti, f)
            else:
                tar.addfile(ti)
    return buf.getvalue()


# --------------------------------------------------------------------------
# Running
# --------------------------------------------------------------------------

@dataclasses.dataclass
class Result:
    plan: Plan
    status: str
    seconds: float
    log: Path | None


def create_container(plan: Plan, bundle: bytes, *, build_only: bool, stack_mib: int,
                     timeout_scale: int, targets: list[str], extra_args: list[str]) -> str:
    """Create (but don't start) a container for the plan's row, with the
    bundle copied in and the driver as its command.  Returns its name."""
    cname = f"stdexec-ci-{_slug(plan.name)}-{os.getpid()}"
    args = ["create", "--name", cname, "--platform", plan.platform]
    args += plan.options
    args += ["-e", f"STDEXEC_CI_BUILD_ONLY={1 if build_only else 0}"]
    stack_bytes = stack_mib * 1024 * 1024
    args += ["--ulimit", f"stack={stack_bytes}:{stack_bytes}"]
    args += ["-e", f"STDEXEC_CI_TIMEOUT_SCALE={timeout_scale}"]
    if os.environ.get("STDEXEC_CI_JOBS"):
        args += ["-e", f"STDEXEC_CI_JOBS={os.environ['STDEXEC_CI_JOBS']}"]
    if targets:
        args += ["-e", "STDEXEC_CI_TARGETS=" + " ".join(targets)]
    args += ["-v", "stdexec-ci-sccache:/var/cache/stdexec-ci/sccache",
             "-v", "stdexec-ci-cpm:/var/cache/stdexec-ci/cpm"]
    for vol, path in plan.mounts:
        args += ["-v", f"{vol}:{path}"]
    args += extra_args
    args += ["--entrypoint", "/bin/bash", plan.image, f"{BUNDLE}/driver.sh"]

    if not DRY_RUN:
        # Pull explicitly for the chosen platform so a tag cached locally for
        # the other architecture isn't silently reused.  (Skipped for images
        # that only exist locally.)
        if docker("pull", "--platform", plan.platform, "-q", plan.image,
                  check=False, quiet=not verbose).returncode != 0:
            if docker("image", "inspect", plan.image, check=False, quiet=True).returncode != 0:
                raise RuntimeError(f"can't pull {plan.image} for {plan.platform}")
    docker(*args, quiet=True)
    try:
        docker("cp", "-", f"{cname}:/", stdin=bundle)
    except BaseException:
        docker("rm", "-f", cname, check=False, quiet=True)
        raise
    return cname


def stream(cmd: list[str], log: Path, *, verbose: bool,
           echo_from: bytes | None = None) -> tuple[int, bool]:
    """Run cmd, writing its combined output to log, and to stdout when
    verbose or from the first line containing echo_from on.  Returns its exit
    status and whether it echoed anything."""
    echoing = verbose
    with open(log, "wb") as lf:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert proc.stdout is not None
        for chunk in iter(lambda: proc.stdout.readline(), b""):
            lf.write(chunk)
            if not echoing and echo_from is not None and echo_from in chunk:
                echoing = True
            if echoing:
                sys.stdout.buffer.write(chunk)
                sys.stdout.flush()
        return proc.wait(), echoing


def run_plan(plan: Plan, bundle: bytes, *, build_only: bool, log: Path | None,
             verbose: bool, keep_failed: bool, stack_mib: int, timeout_scale: int,
             targets: list[str], extra_args: list[str]) -> str:
    cname = create_container(plan, bundle, build_only=build_only, stack_mib=stack_mib,
                             timeout_scale=timeout_scale, targets=targets,
                             extra_args=extra_args)
    status: str | None = None
    try:
        if DRY_RUN:
            docker("start", "-a", cname)
            return "dry-run"
        assert log is not None
        # The driver's banner for the --then step starts the echo, so its
        # output shows without --verbose.
        rc, echoed = stream(["docker", "start", "-a", cname], log, verbose=verbose,
                            echo_from=f"stdexec-ci: {THEN_STEP_NAME}".encode())
        status = "passed" if rc == 0 else ("failed (allowed)" if plan.allow_failure else "FAILED")
        if rc != 0 and not echoed:
            tail = log.read_bytes().splitlines()[-40:]
            print("    ... last lines of the log:")
            for line in tail:
                print("    | " + line.decode(errors="replace"))
        if rc != 0 and keep_failed:
            print(f"    kept container {cname} (docker commit {cname} <image> to explore it; "
                  f"docker rm {cname} when done)")
        return status
    finally:
        if not (keep_failed and status not in (None, "passed")):
            docker("rm", "-f", cname, check=False, quiet=True)


def find_repo(start: Path) -> Path:
    r = subprocess.run(["git", "-C", str(start), "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"stdexec-ci: {start} is not inside a git checkout (use --repo)")
    return Path(r.stdout.strip())


def quick_rows(rows: list[dict[str, Any]], job: dict[str, Any]) -> list[int]:
    """One row per distinct toolchain: the first row for each image (plus any
    from-source compiler commit)."""
    seen, picked = set(), []
    image_expr = (job.get("container") or {}).get("image", "") if isinstance(job.get("container"), dict) else job.get("container", "")
    for i, row in enumerate(rows):
        key = (render(image_expr, {"matrix": row}), row.get("llvm_sha"))
        if key not in seen:
            seen.add(key)
            picked.append(i)
    return picked


def main(argv: list[str] | None = None) -> int:
    global DRY_RUN
    ap = argparse.ArgumentParser(
        prog="stdexec-ci",
        description="Run rows of stdexec's GitHub Actions CI matrix locally in Docker (build-only by default).",
    )
    ap.add_argument("patterns", nargs="*",
                    help="select rows whose name contains any PATTERN (case-insensitive), "
                         "or by number as shown by --list")
    ap.add_argument("--repo", type=Path, help="stdexec checkout (default: the git checkout containing $PWD)")
    ap.add_argument("--workflow", default=".github/workflows/ci.cpu.yml",
                    help="workflow file, relative to the repo (default: %(default)s)")
    ap.add_argument("--job", default="build-cpu", help="job id within the workflow (default: %(default)s)")
    ap.add_argument("-l", "--list", action="store_true", help="list the job's rows and exit")
    ap.add_argument("-a", "--all", action="store_true", help="run every row")
    ap.add_argument("-q", "--quick", action="store_true",
                    help="run one row per distinct toolchain (image + from-source compiler)")
    ap.add_argument("--test", action="store_true", help="also run the tests (ctest, valgrind)")
    ap.add_argument("-t", "--target", action="append", default=[], metavar="TARGET",
                    help="build only TARGET, in place of the targets of every `cmake --build` "
                         "(repeatable)")
    ap.add_argument("--then", metavar="CMD",
                    help=f"after the job, run the shell command CMD in {THEN_DIR} as the build "
                         "step's user, with its environment; its output is shown even "
                         "without --verbose")
    ap.add_argument("--platform", choices=["auto", "amd64"], default="auto",
                    help="auto: arm64 unless a row needs amd64; amd64: every row as CI runs it")
    ap.add_argument("--stack-mib", type=int, default=DEFAULT_STACK_MIB, metavar="MIB",
                    help="the containers' stack size limit (default: %(default)s; Docker's own is 8)")
    ap.add_argument("--emulated-timeout-scale", type=int, default=DEFAULT_EMULATED_TIMEOUT_SCALE,
                    metavar="N", help="multiply test timeouts by N in rows emulated on another "
                                      "architecture (default: %(default)s)")
    ap.add_argument("-j", "--jobs", type=int,
                    help="cap on build parallelism (default: min(VM cpus, VM GiB / 2))")
    ap.add_argument("-v", "--verbose", action="store_true", help="stream build output to the terminal")
    ap.add_argument("--fail-fast", action="store_true", help="stop at the first failing row")
    ap.add_argument("--keep-failed", action="store_true", help="keep the containers of failed rows")
    ap.add_argument("--docker-arg", action="append", default=[], metavar="ARG",
                    help="extra argument for `docker create` (repeatable), e.g. --docker-arg=-eFOO=1")
    ap.add_argument("-n", "--dry-run", action="store_true",
                    help="print the plan and docker commands without running anything")
    ap.add_argument("--dump-bundle", type=Path, metavar="DIR",
                    help="with --dry-run, write each row's generated scripts under DIR")
    args = ap.parse_args(argv)
    DRY_RUN = args.dry_run

    if args.jobs:
        os.environ["STDEXEC_CI_JOBS"] = str(args.jobs)
    if not os.environ.get("DOCKER_CONTEXT") and os.environ.get("STDEXEC_CI_DOCKER_CONTEXT"):
        os.environ["DOCKER_CONTEXT"] = os.environ["STDEXEC_CI_DOCKER_CONTEXT"]

    repo = args.repo.resolve() if args.repo else find_repo(Path.cwd())
    wf_path = repo / args.workflow
    workflow = yaml.safe_load(wf_path.read_text())
    jobs = workflow.get("jobs", {})
    if args.job not in jobs:
        sys.exit(f"stdexec-ci: no job {args.job!r} in {wf_path} (jobs: {', '.join(jobs)})")
    job = jobs[args.job]
    rows = matrix_rows(job)
    quick = quick_rows(rows, job)

    if args.list:
        for i, row in enumerate(rows, 1):
            mark = "q" if i - 1 in quick else " "
            print(f"{i:3} {mark} {_job_name(job, row)}")
        print("\n(q = included in --quick)")
        return 0

    selected: list[int] = []
    if args.all:
        selected = list(range(len(rows)))
    if args.quick:
        selected += quick
    for pat in args.patterns:
        if pat.isdigit():
            selected.append(int(pat) - 1)
        else:
            hits = [i for i, row in enumerate(rows) if pat.lower() in _job_name(job, row).lower()]
            if not hits:
                sys.exit(f"stdexec-ci: no row matches {pat!r} (see --list)")
            selected += hits
    selected = sorted(set(i for i in selected if 0 <= i < len(rows)))
    if not selected:
        ap.error("select rows with PATTERNs, --quick or --all (see --list)")

    vm_arch = "arm64"  # assumed for --dry-run
    if not DRY_RUN:
        r = docker("info", check=False, quiet=True)
        if r.returncode != 0:
            ctx = os.environ.get("DOCKER_CONTEXT", "(default)")
            sys.exit(f"stdexec-ci: can't reach Docker (context {ctx}).\n"
                     "Start the VM by entering `devshell colima-docker` in another terminal.")
        vm_arch = docker("version", "--format", "{{.Server.Arch}}",
                         capture=True).stdout.decode().strip()

    plans = [make_plan(args.job, job, rows[i], platform_choice=args.platform,
                       probe_caches=not DRY_RUN) for i in selected]
    if args.then:
        for p in plans:
            add_then(p, args.then)
    # Run rows grouped by (image, platform): the classic Docker image store
    # keeps one platform per tag, so alternating platforms re-pulls images.
    order = sorted(range(len(plans)), key=lambda k: (plans[k].image, plans[k].platform, k))

    print(f"stdexec-ci: {len(plans)} row(s) from {args.workflow}:{args.job}, "
          f"{'build and test' if args.test else 'build only'}"
          + (f", targets: {' '.join(args.target)}" if args.target else "")
          + (f", then: {args.then}" if args.then else ""))
    for p in plans:
        print(f"  - {p.name}  [{p.platform.split('/')[1]}: {p.platform_reason}]")

    src = source_tarball(repo)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    log_dir = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "stdexec-ci" / "logs" / stamp
    if not DRY_RUN:
        log_dir.mkdir(parents=True, exist_ok=True)

    results: list[Result] = []
    try:
        for k in order:
            p = plans[k]
            bundle = build_bundle(p, src)
            if DRY_RUN and args.dump_bundle:
                dest = args.dump_bundle / _slug(p.name)
                dest.mkdir(parents=True, exist_ok=True)
                with tarfile.open(fileobj=io.BytesIO(bundle)) as t:
                    t.extractall(dest, filter="data",
                                 members=[m for m in t.getmembers() if not m.name.endswith("source.tar")])
            log = None if DRY_RUN else log_dir / f"{_slug(p.name)}.log"
            print(f"\n>>> {p.name}  [{p.platform}]" + (f"  log: {log}" if log else ""))
            t0 = time.monotonic()
            status = run_plan(p, bundle, build_only=not args.test, log=log,
                              verbose=args.verbose, keep_failed=args.keep_failed,
                              stack_mib=args.stack_mib,
                              timeout_scale=(1 if p.platform == f"linux/{vm_arch}"
                                             else args.emulated_timeout_scale),
                              targets=args.target, extra_args=args.docker_arg)
            results.append(Result(p, status, time.monotonic() - t0, log))
            print(f"<<< {status} in {time.monotonic() - t0:.0f}s")
            if status == "FAILED" and args.fail_fast:
                break
    except KeyboardInterrupt:
        print("\nstdexec-ci: interrupted")
        results.append(Result(plans[k], "interrupted", 0, None))

    print("\nSummary:")
    width = max(len(r.plan.name) for r in results) if results else 0
    for r in results:
        print(f"  {r.status:<17} {r.plan.name:<{width}}  {r.seconds:6.0f}s  {r.plan.platform.split('/')[1]}")
    if log_dir.exists():
        print(f"Logs: {log_dir}")
    return 1 if any(r.status in ("FAILED", "interrupted") for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
