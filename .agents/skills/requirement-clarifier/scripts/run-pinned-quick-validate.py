#!/usr/bin/env python3
"""Run Skill Creator quick_validate with an explicitly loaded PyYAML package."""

from __future__ import annotations

import argparse
import importlib.util
import runpy
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pyyaml-package", required=True)
    parser.add_argument("--quick-validate", required=True)
    parser.add_argument("--skill-root", required=True)
    args = parser.parse_args()
    sys.dont_write_bytecode = True

    package_root = Path(args.pyyaml_package).resolve(strict=True)
    package_init = package_root / "__init__.py"
    quick_validate = Path(args.quick_validate).resolve(strict=True)
    skill_root = Path(args.skill_root).resolve(strict=True)

    if package_root.name != "yaml" or not package_init.is_file():
        parser.error("--pyyaml-package must point to the yaml package directory")
    if not quick_validate.is_file() or quick_validate.suffix != ".py":
        parser.error("--quick-validate must point to a Python file")
    if not skill_root.is_dir():
        parser.error("--skill-root must point to a directory")

    spec = importlib.util.spec_from_file_location(
        "yaml",
        package_init,
        submodule_search_locations=[str(package_root)],
    )
    if spec is None or spec.loader is None:
        parser.error("cannot create a module spec for the pinned PyYAML package")
    yaml_module = importlib.util.module_from_spec(spec)
    sys.modules["yaml"] = yaml_module
    spec.loader.exec_module(yaml_module)

    sys.argv = [str(quick_validate), str(skill_root)]
    runpy.run_path(str(quick_validate), run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
