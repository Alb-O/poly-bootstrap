#!/usr/bin/env python3
import argparse
import json
import os
import sys

import yaml


def fail(message):
    raise SystemExit(message)


def repo_name_from_url(url):
    cleaned = url.split("?", 1)[0].split("#", 1)[0].removeprefix("git+")

    if cleaned.startswith("github:"):
        cleaned = cleaned.removeprefix("github:")
    elif "github.com/" in cleaned:
        cleaned = cleaned.split("github.com/", 1)[1]

    cleaned = cleaned.rstrip("/").removesuffix(".git")
    cleaned = cleaned.rsplit("/", 1)[-1]
    return cleaned or None


def get_inputs_block(source_label, yaml_text):
    parsed = yaml.safe_load(yaml_text) or {}
    if not isinstance(parsed, dict):
        fail(f"expected a top-level mapping in {source_label}")

    inputs_block = parsed.get("inputs", {}) or {}
    if not isinstance(inputs_block, dict):
        fail(f"expected `inputs` to be a mapping in {source_label}")

    return inputs_block


def read_input_spec(input_spec):
    if isinstance(input_spec, dict):
        url = input_spec.get("url")
        if isinstance(url, str) and url:
            return url, dict(input_spec)
    elif isinstance(input_spec, str) and input_spec:
        return input_spec, {}
    return None, None


def read_local_repo_names(repo_names_json_path):
    with open(repo_names_json_path, "r", encoding="utf-8") as handle:
        parsed = json.load(handle) or []

    if not isinstance(parsed, list):
        fail("expected local repo names JSON to be a list")

    names = set()
    for item in parsed:
        if isinstance(item, str) and item:
            names.add(item)

    return names


def read_repo_sources(repo_sources_json_path):
    with open(repo_sources_json_path, "r", encoding="utf-8") as handle:
        parsed = json.load(handle) or {}

    if not isinstance(parsed, dict):
        fail("expected repo sources JSON to be a mapping")

    repo_sources = {}
    for repo_name, yaml_text in parsed.items():
        if isinstance(repo_name, str) and repo_name and isinstance(yaml_text, str):
            repo_sources[repo_name] = yaml_text

    return repo_sources


def add_override(overrides, input_name, copied_spec, source_label):
    existing_spec = overrides.get(input_name)
    if existing_spec is None:
        overrides[input_name] = copied_spec
        return

    if existing_spec != copied_spec:
        fail(
            f"conflicting local override for input '{input_name}' while scanning {source_label}"
        )


def build_overrides(source_yaml_text, local_repo_names, repo_sources, repos_root, url_scheme):
    url_prefix = "git+file:" if url_scheme == "git+file" else "path:"

    overrides = {}
    visited_repo_names = set()
    pending_sources = [("root source", source_yaml_text)]

    while pending_sources:
        source_label, pending_yaml_text = pending_sources.pop(0)

        for input_name, input_spec in get_inputs_block(
            source_label, pending_yaml_text
        ).items():
            input_url, copied_spec = read_input_spec(input_spec)

            if input_url is None:
                continue

            repo_name = repo_name_from_url(input_url)
            if not repo_name or repo_name not in local_repo_names:
                continue

            local_repo_path = os.path.join(repos_root, repo_name)
            copied_spec["url"] = f"{url_prefix}{local_repo_path}"
            add_override(overrides, str(input_name), copied_spec, source_label)

            if repo_name in visited_repo_names:
                continue

            nested_source = repo_sources.get(repo_name)
            if nested_source is None:
                continue

            visited_repo_names.add(repo_name)
            pending_sources.append((f"local repo '{repo_name}'", nested_source))

    return overrides


def render_overrides_text(overrides):
    if not overrides:
        return ""

    return yaml.safe_dump(
        {"inputs": {name: overrides[name] for name in sorted(overrides)}},
        sort_keys=True,
        default_flow_style=False,
    )


def run_generator_mode(
    source_yaml_path, local_repo_names_path, repo_sources_json_path, repos_root, url_scheme
):
    local_repo_names = read_local_repo_names(local_repo_names_path)
    repo_sources = read_repo_sources(repo_sources_json_path)

    with open(source_yaml_path, "r", encoding="utf-8") as handle:
        source_yaml_text = handle.read()

    overrides = build_overrides(
        source_yaml_text, local_repo_names, repo_sources, repos_root, url_scheme
    )
    sys.stdout.write(render_overrides_text(overrides))
    return 0


def resolve_repo_path(repo_root, candidate_path):
    if os.path.isabs(candidate_path):
        return os.path.normpath(candidate_path)
    return os.path.normpath(os.path.join(repo_root, candidate_path))


def maybe_relativize(path, root):
    root = os.path.normpath(root)
    path = os.path.normpath(path)
    root_prefix = root + os.sep

    if path == root:
        return "."
    if path.startswith(root_prefix):
        return path[len(root_prefix) :]
    return None


def sync_local_overrides(repo_root, source_path, output_path, repos_root, url_scheme):
    repo_root = os.path.realpath(repo_root)
    source_yaml_path = resolve_repo_path(repo_root, source_path)
    output_yaml_path = resolve_repo_path(repo_root, output_path)
    repos_root = os.path.realpath(repos_root)

    with open(source_yaml_path, "r", encoding="utf-8") as handle:
        source_yaml_text = handle.read()

    source_relative_path = maybe_relativize(source_yaml_path, repo_root)
    repo_names = {
        entry
        for entry in os.listdir(repos_root)
        if os.path.isdir(os.path.join(repos_root, entry))
    }

    repo_sources = {}
    if source_relative_path is not None:
        for repo_name in repo_names:
            nested_path = os.path.join(repos_root, repo_name, source_relative_path)
            if os.path.isfile(nested_path):
                with open(nested_path, "r", encoding="utf-8") as handle:
                    repo_sources[repo_name] = handle.read()

    overrides = build_overrides(
        source_yaml_text, repo_names, repo_sources, repos_root, url_scheme
    )
    overrides_text = render_overrides_text(overrides)

    if overrides_text == "":
        if os.path.lexists(output_yaml_path):
            os.remove(output_yaml_path)
        return 0

    existing_text = None
    if os.path.exists(output_yaml_path):
        with open(output_yaml_path, "r", encoding="utf-8") as handle:
            existing_text = handle.read()

    if existing_text != overrides_text:
        if os.path.lexists(output_yaml_path):
            os.remove(output_yaml_path)
        with open(output_yaml_path, "w", encoding="utf-8") as handle:
            handle.write(overrides_text)

    return 0


def parse_args(argv):
    if len(argv) == 5:
        return ("generate", argv)

    parser = argparse.ArgumentParser(
        description="Generate devenv.local.yaml local path overrides for sibling repos."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync_parser = subparsers.add_parser("sync")
    sync_parser.add_argument("repo_root", nargs="?", default=".")
    sync_parser.add_argument("--source-path", default="devenv.yaml")
    sync_parser.add_argument("--output-path", default="devenv.local.yaml")
    sync_parser.add_argument("--repos-root")
    sync_parser.add_argument("--url-scheme", choices=["path", "git+file"], default="path")

    return ("cli", parser.parse_args(argv))


def main():
    mode, parsed = parse_args(sys.argv[1:])

    if mode == "generate":
        source_yaml_path, local_repo_names_path, repo_sources_json_path, repos_root, url_scheme = (
            parsed
        )
        return run_generator_mode(
            source_yaml_path,
            local_repo_names_path,
            repo_sources_json_path,
            repos_root,
            url_scheme,
        )

    repo_root = os.path.realpath(parsed.repo_root)
    repos_root = (
        os.path.realpath(parsed.repos_root)
        if parsed.repos_root is not None
        else os.path.dirname(repo_root)
    )
    return sync_local_overrides(
        repo_root,
        parsed.source_path,
        parsed.output_path,
        repos_root,
        parsed.url_scheme,
    )


if __name__ == "__main__":
    raise SystemExit(main())
