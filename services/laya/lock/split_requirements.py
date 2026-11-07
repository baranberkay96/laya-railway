"""Split a `uv export` requirements file into torch (PyTorch CPU index) and the rest (PyPI).

Usage (from services/laya/lock):
    uv lock --python 3.11
    uv export --frozen --no-dev --no-emit-project --format requirements-txt --python 3.11 -o /tmp/laya-req.txt
    python3 split_requirements.py /tmp/laya-req.txt ../requirements-torch.txt ../requirements.txt

Environment markers are dropped on purpose: a build on anything but linux/x86_64 should fail on
the hashes instead of silently installing nothing.
"""
import re
import sys

HEADER = (
    "# Generated from lock/pyproject.toml with uv (see TEMPLATE.md, \"Upgrading\").\n"
    "# Linux x86_64, CPython 3.11. Every file is pinned by SHA-256; pip runs with\n"
    "# --require-hashes --no-deps --only-binary=:all:.\n"
)


def read_blocks(path: str) -> list:
    blocks, current = [], []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if re.match(r"^[A-Za-z0-9]", line):
                if current:
                    blocks.append(current)
                current = [line]
            elif current and line.lstrip().startswith("--hash="):
                current.append(line)
    if current:
        blocks.append(current)
    return blocks


def render(block: list) -> str:
    requirement = block[0].split(";")[0].rstrip(" \\\n")
    hashes = [line.strip().rstrip("\\").rstrip() for line in block[1:]]
    lines = [requirement + (" \\" if hashes else "")]
    for index, digest in enumerate(hashes):
        lines.append("    " + digest + (" \\" if index < len(hashes) - 1 else ""))
    return "\n".join(lines) + "\n"


def main() -> int:
    source, out_torch, out_rest = sys.argv[1:4]
    blocks = read_blocks(source)
    torch = [b for b in blocks if b[0].startswith("torch==")]
    rest = [b for b in blocks if not b[0].startswith("torch==")]
    if len(torch) != 1 or not all(len(b) > 1 for b in blocks):
        raise SystemExit("expected exactly one torch pin and a hash on every requirement")
    with open(out_torch, "w", encoding="utf-8") as handle:
        handle.write(HEADER + "# Installed from https://download.pytorch.org/whl/cpu only.\n")
        handle.writelines(render(b) for b in torch)
    with open(out_rest, "w", encoding="utf-8") as handle:
        handle.write(HEADER + "# Installed from https://pypi.org/simple only (torch comes from "
                     "requirements-torch.txt).\n")
        handle.writelines(render(b) for b in rest)
    print("%d torch + %d other pins written" % (len(torch), len(rest)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
