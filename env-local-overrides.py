#!/usr/bin/env python3
import os
import sys

import yaml


def repo_name_from_url(url):
    cleaned = url.split("?", 1)[0].split("#", 1)[0].removeprefix("git+")

    if cleaned.startswith("github:"):
        cleaned = cleaned.removeprefix("github:")
    elif "github.com/" in cleaned:
        cleaned = cleaned.split("github.com/", 1)[1]

    cleaned = cleaned.rstrip("/").removesuffix(".git")
    cleaned = cleaned.rsplit("/", 1)[-1]
    return cleaned or None


def get_inputs_block(source_yaml_path):
    with open(source_yaml_path, "r", encoding="utf-8") as handle:
        parsed = yaml.safe_load(handle) or {}

    if not isinstance(parsed, dict):
        raise SystemExit("expected a top-level mapping")

    inputs_block = parsed.get("inputs", {}) or {}
    if not isinstance(inputs_block, dict):
        raise SystemExit("expected `inputs` to be a mapping")

    return inputs_block


def read_input_spec(input_spec):
    if isinstance(input_spec, dict):
        url = input_spec.get("url")
        if isinstance(url, str) and url:
            return url, dict(input_spec)
    elif isinstance(input_spec, str) and input_spec:
        return input_spec, {}
    return None, None


def main() -> int:
    source_yaml_path, repos_root, url_scheme = sys.argv[1:4]
    url_prefix = "git+file:" if url_scheme == "git+file" else "path:"

    overrides = {}

    for input_name, input_spec in get_inputs_block(source_yaml_path).items():
        input_url, copied_spec = read_input_spec(input_spec)

        if input_url is None:
            continue

        repo_name = repo_name_from_url(input_url)
        if not repo_name:
            continue

        local_repo_path = os.path.join(repos_root, repo_name)
        if not os.path.isdir(local_repo_path):
            continue

        copied_spec["url"] = f"{url_prefix}{local_repo_path}"
        overrides[str(input_name)] = copied_spec

    if not overrides:
        return 0

    yaml.safe_dump(
        {"inputs": {name: overrides[name] for name in sorted(overrides)}},
        sys.stdout,
        sort_keys=True,
        default_flow_style=False,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
