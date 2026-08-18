import re
import sys
import tomllib

pyproject_path, provided = sys.argv[1], sys.argv[2].split()
provided_normalized = {re.sub(r"[-_.]+", "-", n).lower() for n in provided}

with open(pyproject_path, "rb") as f:
    data = tomllib.load(f)

declared = data.get("project", {}).get("dependencies", [])
missing = []
for req in declared:
    name = re.split(r"[\s<>=!~\[;]", req, maxsplit=1)[0]
    normalized = re.sub(r"[-_.]+", "-", name).lower()
    if normalized not in provided_normalized:
        missing.append(name)

if missing:
    print(
        "cladoscope-dev: WARNING: pyproject.toml declares "
        + ", ".join(missing)
        + " which lib/cladoscope-python-deps.nix doesn't provide"
        + " -- add it there or imports may fail.",
        file=sys.stderr,
    )
