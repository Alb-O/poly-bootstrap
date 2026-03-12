#!/usr/bin/env python3
import argparse
import json
import os
import sys

import yaml

GLOBAL_INPUTS_BASENAME = ".devenv-global-inputs.yaml"


def fail(message):
    raise SystemExit(message)


def parse_top_level_mapping(source_label, yaml_text):
    parsed = yaml.safe_load(yaml_text) or {}
    if not isinstance(parsed, dict):
        fail(f"expected a top-level mapping in {source_label}")

    return parsed


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
    parsed = parse_top_level_mapping(source_label, yaml_text)
    inputs_block = parsed.get("inputs", {}) or {}
    if not isinstance(inputs_block, dict):
        fail(f"expected `inputs` to be a mapping in {source_label}")

    return inputs_block


def get_input_names(source_label, yaml_text):
    return {str(input_name) for input_name in get_inputs_block(source_label, yaml_text)}


def get_imports_list(source_label, yaml_text):
    parsed = parse_top_level_mapping(source_label, yaml_text)
    imports_list = parsed.get("imports", []) or []
    if not isinstance(imports_list, list):
        fail(f"expected `imports` to be a list in {source_label}")

    names = []
    for item in imports_list:
        if not isinstance(item, str) or not item:
            fail(f"expected `imports` entries to be non-empty strings in {source_label}")
        names.append(item)

    return names


def get_import_input_name(import_name):
    if import_name.startswith(("path:", "/", "./", "../")):
        return None
    return import_name.split("/", 1)[0] or None


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


def read_name_filter(json_path, label):
    with open(json_path, "r", encoding="utf-8") as handle:
        parsed = json.load(handle) or []

    if not isinstance(parsed, list):
        fail(f"expected {label} JSON to be a list")

    names = set()
    for item in parsed:
        if isinstance(item, str) and item:
            names.add(item)

    return names


def fail_on_overlap(first_names, second_names, first_label, second_label):
    overlap = sorted(first_names & second_names)
    if overlap:
        fail(f"{first_label} and {second_label} must not overlap: {', '.join(overlap)}")


def add_override(overrides, input_name, copied_spec, source_label):
    existing_spec = overrides.get(input_name)
    if existing_spec is None:
        overrides[input_name] = copied_spec
        return

    if existing_spec != copied_spec:
        fail(
            f"conflicting local override for input '{input_name}' while scanning {source_label}"
        )


def append_unique_name(names, name):
    if name not in names:
        names.append(name)


def build_overrides(
    source_yaml_text,
    global_inputs_yaml_text,
    local_repo_names,
    repo_sources,
    include_inputs,
    exclude_inputs,
    repo_dirs_root,
    url_scheme,
):
    url_prefix = "git+file:" if url_scheme == "git+file" else "path:"

    overrides = {}
    rendered_imports = []
    visited_repo_names = set()
    root_input_names = get_input_names("root source", source_yaml_text)
    global_imports = []
    pending_sources = [("root source", source_yaml_text, set())]
    if global_inputs_yaml_text:
        global_imports = get_imports_list(
            f"global inputs '{GLOBAL_INPUTS_BASENAME}'", global_inputs_yaml_text
        )
        pending_sources.append(
            (
                f"global inputs '{GLOBAL_INPUTS_BASENAME}'",
                global_inputs_yaml_text,
                root_input_names,
            )
        )

    while pending_sources:
        source_label, pending_yaml_text, blocked_input_names = pending_sources.pop(0)

        for input_name, input_spec in get_inputs_block(
            source_label, pending_yaml_text
        ).items():
            input_name = str(input_name)
            if input_name in blocked_input_names:
                continue
            if include_inputs and input_name not in include_inputs:
                continue
            if input_name in exclude_inputs:
                continue

            input_url, copied_spec = read_input_spec(input_spec)

            if input_url is None:
                continue

            repo_name = repo_name_from_url(input_url)
            if not repo_name or repo_name not in local_repo_names:
                continue

            local_repo_path = os.path.join(repo_dirs_root, repo_name)
            copied_spec["url"] = f"{url_prefix}{local_repo_path}"
            add_override(overrides, input_name, copied_spec, source_label)

            if repo_name in visited_repo_names:
                continue

            nested_source = repo_sources.get(repo_name)
            if nested_source is None:
                continue

            visited_repo_names.add(repo_name)
            pending_sources.append((f"local repo '{repo_name}'", nested_source, set()))

    effective_input_names = root_input_names | set(overrides)
    for import_name in global_imports:
        import_input_name = get_import_input_name(import_name) or import_name
        if include_inputs and import_input_name not in include_inputs:
            continue
        if import_input_name in exclude_inputs:
            continue
        if import_input_name in effective_input_names:
            append_unique_name(rendered_imports, import_name)

    return overrides, rendered_imports


def render_overrides_text(overrides, imports_list):
    if not overrides and not imports_list:
        return ""

    rendered = {}
    if overrides:
        rendered["inputs"] = {name: overrides[name] for name in sorted(overrides)}
    if imports_list:
        rendered["imports"] = imports_list

    return yaml.safe_dump(rendered, sort_keys=False, default_flow_style=False)


def run_generator_mode(
    source_yaml_path,
    local_repo_names_path,
    repo_sources_json_path,
    global_inputs_yaml_path,
    include_inputs_json_path,
    exclude_inputs_json_path,
    repo_dirs_root,
    url_scheme,
):
    local_repo_names = read_local_repo_names(local_repo_names_path)
    repo_sources = read_repo_sources(repo_sources_json_path)
    global_inputs_yaml_text = ""
    with open(global_inputs_yaml_path, "r", encoding="utf-8") as handle:
        global_inputs_yaml_text = handle.read()
    include_inputs = read_name_filter(include_inputs_json_path, "included inputs")
    exclude_inputs = read_name_filter(exclude_inputs_json_path, "excluded inputs")
    fail_on_overlap(include_inputs, exclude_inputs, "included inputs", "excluded inputs")

    with open(source_yaml_path, "r", encoding="utf-8") as handle:
        source_yaml_text = handle.read()

    overrides, imports_list = build_overrides(
        source_yaml_text,
        global_inputs_yaml_text,
        local_repo_names,
        repo_sources,
        include_inputs,
        exclude_inputs,
        repo_dirs_root,
        url_scheme,
    )
    sys.stdout.write(render_overrides_text(overrides, imports_list))
    return 0


def resolve_repo_path(repo_root, candidate_path):
    if os.path.isabs(candidate_path):
        return os.path.normpath(candidate_path)
    return os.path.normpath(os.path.join(repo_root, candidate_path))


def resolve_repo_dirs_root(polyrepo_root, repo_dirs_path):
    if os.path.isabs(repo_dirs_path):
        return os.path.normpath(repo_dirs_path)
    return os.path.normpath(os.path.join(polyrepo_root, repo_dirs_path))


def infer_polyrepo_root(repo_root, repo_dirs_path):
    if os.path.isabs(repo_dirs_path):
        return None

    repo_root = os.path.normpath(repo_root)
    repo_parent = os.path.dirname(repo_root)
    repo_dirs_path = os.path.normpath(repo_dirs_path)

    if repo_dirs_path in ("", "."):
        return repo_parent

    candidate_polyrepo_root = repo_parent
    for _ in repo_dirs_path.split(os.sep):
        candidate_polyrepo_root = os.path.dirname(candidate_polyrepo_root)

    candidate_repo_dirs_root = os.path.normpath(
        os.path.join(candidate_polyrepo_root, repo_dirs_path)
    )
    if repo_parent == candidate_repo_dirs_root:
        return candidate_polyrepo_root

    return None


def resolve_polyrepo_root(repo_root, polyrepo_root, repo_dirs_path):
    if polyrepo_root is not None:
        return os.path.realpath(resolve_repo_path(repo_root, polyrepo_root))

    inferred = infer_polyrepo_root(repo_root, repo_dirs_path)
    if inferred is None:
        fail(
            "polyrepo root could not be inferred; pass --polyrepo-root when the current repo is not nested under --repo-dirs-path"
        )

    return os.path.realpath(inferred)


def maybe_relativize(path, root):
    root = os.path.normpath(root)
    path = os.path.normpath(path)
    root_prefix = root + os.sep

    if path == root:
        return "."
    if path.startswith(root_prefix):
        return path[len(root_prefix) :]
    return None


def sync_local_overrides(
    repo_root,
    source_path,
    output_path,
    polyrepo_root,
    repo_dirs_path,
    url_scheme,
    include_repos,
    exclude_repos,
    include_inputs,
    exclude_inputs,
):
    repo_root = os.path.realpath(repo_root)
    source_yaml_path = resolve_repo_path(repo_root, source_path)
    output_yaml_path = resolve_repo_path(repo_root, output_path)
    polyrepo_root = resolve_polyrepo_root(repo_root, polyrepo_root, repo_dirs_path)
    repo_dirs_root = os.path.realpath(resolve_repo_dirs_root(polyrepo_root, repo_dirs_path))
    fail_on_overlap(include_repos, exclude_repos, "included repos", "excluded repos")
    fail_on_overlap(include_inputs, exclude_inputs, "included inputs", "excluded inputs")

    with open(source_yaml_path, "r", encoding="utf-8") as handle:
        source_yaml_text = handle.read()
    global_inputs_yaml_path = os.path.join(polyrepo_root, GLOBAL_INPUTS_BASENAME)
    global_inputs_yaml_text = ""
    if os.path.isfile(global_inputs_yaml_path):
        with open(global_inputs_yaml_path, "r", encoding="utf-8") as handle:
            global_inputs_yaml_text = handle.read()

    source_relative_path = maybe_relativize(source_yaml_path, repo_root)
    repo_names = {
        entry
        for entry in os.listdir(repo_dirs_root)
        if os.path.isdir(os.path.join(repo_dirs_root, entry))
    }
    if include_repos:
        repo_names = {entry for entry in repo_names if entry in include_repos}
    repo_names = {entry for entry in repo_names if entry not in exclude_repos}

    repo_sources = {}
    if source_relative_path is not None:
        for repo_name in repo_names:
            nested_path = os.path.join(repo_dirs_root, repo_name, source_relative_path)
            if os.path.isfile(nested_path):
                with open(nested_path, "r", encoding="utf-8") as handle:
                    repo_sources[repo_name] = handle.read()

    overrides, imports_list = build_overrides(
        source_yaml_text,
        global_inputs_yaml_text,
        repo_names,
        repo_sources,
        include_inputs,
        exclude_inputs,
        repo_dirs_root,
        url_scheme,
    )
    overrides_text = render_overrides_text(overrides, imports_list)

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
    if len(argv) == 8:
        return ("generate", argv)

    parser = argparse.ArgumentParser(
        description="Generate devenv.local.yaml local path overrides for sibling repos."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync_parser = subparsers.add_parser("sync")
    sync_parser.add_argument("repo_root", nargs="?", default=".")
    sync_parser.add_argument("--source-path", default="devenv.yaml")
    sync_parser.add_argument("--output-path", default="devenv.local.yaml")
    sync_parser.add_argument("--polyrepo-root")
    sync_parser.add_argument("--repo-dirs-path", default="repos")
    sync_parser.add_argument("--url-scheme", choices=["path", "git+file"], default="path")
    sync_parser.add_argument("--include-repo", action="append", default=[])
    sync_parser.add_argument("--exclude-repo", action="append", default=[])
    sync_parser.add_argument("--include-input", action="append", default=[])
    sync_parser.add_argument("--exclude-input", action="append", default=[])

    return ("cli", parser.parse_args(argv))


def main():
    mode, parsed = parse_args(sys.argv[1:])

    if mode == "generate":
        (
            source_yaml_path,
            local_repo_names_path,
            repo_sources_json_path,
            global_inputs_yaml_path,
            include_inputs_json_path,
            exclude_inputs_json_path,
            repo_dirs_root,
            url_scheme,
        ) = parsed
        return run_generator_mode(
            source_yaml_path,
            local_repo_names_path,
            repo_sources_json_path,
            global_inputs_yaml_path,
            include_inputs_json_path,
            exclude_inputs_json_path,
            repo_dirs_root,
            url_scheme,
        )

    repo_root = os.path.realpath(parsed.repo_root)
    return sync_local_overrides(
        repo_root,
        parsed.source_path,
        parsed.output_path,
        parsed.polyrepo_root,
        parsed.repo_dirs_path,
        parsed.url_scheme,
        set(parsed.include_repo),
        set(parsed.exclude_repo),
        set(parsed.include_input),
        set(parsed.exclude_input),
    )


if __name__ == "__main__":
    raise SystemExit(main())
