# Vulture whitelist (vulture convention: a file of dummy references passed
# in [tool.vulture].paths). Reserved for symbols vulture can't see because
# they're only reached via strings (console-script entry points in
# pyproject.toml `[project.scripts]`, the uvicorn `src.main:app` ASGI entry)
# should such a symbol ever get flagged. Nothing needs an entry today: the
# console-script `main()` functions are each called from their module's
# `if __name__ == "__main__":` guard, and `main.app` is a plain top-level
# assignment vulture does not treat as unused. Prefer [tool.vulture]
# ignore_names in pyproject.toml for simple false positives (e.g. framework
# config attributes, dataclass/Pydantic fields only ever set via kwargs);
# use this file only when a dummy reference is actually required.
