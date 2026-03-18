use support.nu [fail]

def normalize-structured-value [value: any]: nothing -> any {
  match ($value | describe) {
    $t if $t =~ '^record' => {
      $value
      | items {|key, item| [$key (normalize-structured-value $item)] }
      | into record
    }
    $t if $t =~ '^list' => { $value | each {|item| normalize-structured-value $item } }
    _ => { $value }
  }
}

export def parse-top-level-mapping [source_label: string yaml_text: string]: nothing -> oneof<record, error> {
  let parsed = if ($yaml_text | str trim) == "" {
    {}
  } else {
    try {
      $yaml_text | from yaml | default {}
    } catch {
      fail $"expected a top-level mapping in ($source_label)"
    }
  }

  if (($parsed | describe) !~ '^record') {
    fail $"expected a top-level mapping in ($source_label)"
  }

  normalize-structured-value $parsed
}

export def parse-top-level-nuon-mapping [source_label: string nuon_text: string]: nothing -> oneof<record, error> {
  let parsed = if ($nuon_text | str trim) == "" {
    {}
  } else {
    try {
      $nuon_text | from nuon | default {}
    } catch {
      fail $"expected a top-level mapping in ($source_label)"
    }
  }

  if (($parsed | describe) !~ '^record') {
    fail $"expected a top-level mapping in ($source_label)"
  }

  normalize-structured-value $parsed
}

export def get-inputs-block [source_label: string yaml_text: string]: nothing -> oneof<record, error> {
  let parsed = parse-top-level-mapping $source_label $yaml_text
  let inputs_block = ($parsed | get -o inputs | default {})

  if (($inputs_block | describe) !~ '^record') {
    fail $"expected `inputs` to be a mapping in ($source_label)"
  }

  $inputs_block
}

export def get-input-names [source_label: string yaml_text: string]: nothing -> list<string> {
  get-inputs-block $source_label $yaml_text | columns
}

export def get-imports-list [source_label: string yaml_text: string]: nothing -> oneof<list<string>, error> {
  let parsed = parse-top-level-mapping $source_label $yaml_text
  let imports_list = ($parsed | get -o imports | default [])

  if (($imports_list | describe) !~ '^list') {
    fail $"expected `imports` to be a list in ($source_label)"
  }

  $imports_list
  | each {|item|
      if (($item | describe) != 'string') or ($item | is-empty) {
        fail $"expected `imports` entries to be non-empty strings in ($source_label)"
      }

      $item
    }
}

export def read-input-spec [input_spec: any]: nothing -> oneof<record, nothing> {
  match ($input_spec | describe) {
    $t if $t =~ '^record' => {
      let url = ($input_spec | get -o url)

      if (($url | describe) == 'string') and (not ($url | is-empty)) {
        {
          url: $url
          spec: $input_spec
        }
      }
    }
    "string" => {
      if ($input_spec | is-empty) {
        null
      } else {
        {
          url: $input_spec
          spec: {}
        }
      }
    }
    _ => { null }
  }
}

export def parse-json-record [json_path: path message: string]: nothing -> oneof<record, error> {
  let parsed = try {
    open --raw $json_path | from json | default {}
  } catch {
    fail $message
  }

  if (($parsed | describe) !~ '^record') {
    fail $message
  }

  $parsed
}

export def expect-string-list [value: any field_label: string]: nothing -> oneof<list<string>, error> {
  if (($value | describe) !~ '^list') {
    fail $"expected ($field_label) to be a list"
  }

  $value
  | each {|item|
      if (($item | describe) != 'string') or ($item | is-empty) {
        fail $"expected ($field_label) entries to be non-empty strings"
      }

      $item
    }
  | uniq
}

export def expect-string-record [value: any field_label: string]: nothing -> oneof<record, error> {
  if (($value | describe) !~ '^record') {
    fail $"expected ($field_label) to be a mapping"
  }

  $value
  | items {|key, item|
      if ($key | is-empty) {
        fail $"expected ($field_label) keys to be non-empty strings"
      }

      if (($item | describe) != 'string') {
        fail $"expected ($field_label) values to be strings"
      }

      [$key $item]
    }
  | into record
}

def expect-optional-string-list [value: any source_label: string field_label: string]: nothing -> oneof<list<string>, error> {
  if (($value | describe) == 'nothing') {
    return []
  }

  if (($value | describe) !~ '^list') {
    fail $"expected ($field_label) in ($source_label) to be a list"
  }

  $value
  | each {|item|
      if (($item | describe) != 'string') or ($item | is-empty) {
        fail $"expected ($field_label) in ($source_label) to be non-empty strings"
      }

      $item
    }
}

def normalize-polyrepo-input-entry [input_name: string input_value: any manifest_label: string]: nothing -> oneof<record, error> {
  let source_label = $"inputs.($input_name) in ($manifest_label)"

  match ($input_value | describe) {
    "string" => {
      if ($input_value | is-empty) {
        fail $"expected ($source_label) to be a non-empty string or mapping"
      }

      {
        spec: { url: $input_value }
        imports: []
        localRepo: null
      }
    }
    $t if $t =~ '^record' => {
      let entry_spec = (
        $input_value
        | reject --optional imports localRepo
      )
      let local_repo = ($input_value | get -o localRepo)
      let url = ($entry_spec | get -o url)

      if (($url | describe) != 'string') or ($url | is-empty) {
        fail $"expected ($source_label) to define a non-empty url"
      }

      let normalized_local_repo = if (($local_repo | describe) == 'nothing') {
        null
      } else if (($local_repo | describe) == 'string') and (not ($local_repo | is-empty)) {
        $local_repo
      } else {
        fail $"expected localRepo in ($source_label) to be a non-empty string"
      }

      {
        spec: $entry_spec
        imports: (expect-optional-string-list ($input_value | get -o imports) $source_label "imports")
        localRepo: $normalized_local_repo
      }
    }
    _ => {
      fail $"expected ($source_label) to be a non-empty string or mapping"
    }
  }
}

def normalize-polyrepo-overlay-entry [overlay_type: string overlay_name: string overlay_value: any manifest_label: string]: nothing -> oneof<record, error> {
  let source_label = $"($overlay_type).($overlay_name) in ($manifest_label)"

  if (($overlay_value | describe) !~ '^record') {
    fail $"expected ($source_label) to be a mapping"
  }

  {
    extends: (expect-optional-string-list ($overlay_value | get -o extends) $source_label "extends")
    inputs: (expect-optional-string-list ($overlay_value | get -o inputs) $source_label "inputs")
    imports: (expect-optional-string-list ($overlay_value | get -o imports) $source_label "imports")
  }
}

def normalize-polyrepo-repo-entry [repo_value: any manifest_label: string]: nothing -> oneof<record, error> {
  let source_label = $"repos entry in ($manifest_label)"

  if (($repo_value | describe) !~ '^record') {
    fail $"expected ($source_label) to be a mapping"
  }

  let repo_path = ($repo_value | get -o path)
  if (($repo_path | describe) != 'string') or ($repo_path | is-empty) {
    fail $"expected path in ($source_label) to be a non-empty string"
  }

  let repo_name = ($repo_value | get -o name | default ($repo_path | path basename))
  if (($repo_name | describe) != 'string') or ($repo_name | is-empty) {
    fail $"expected name in ($source_label) to be a non-empty string"
  }

  let bundle = ($repo_value | get -o bundle)
  let bundle = if (($bundle | describe) == 'nothing') {
    null
  } else if (($bundle | describe) == 'string') and (not ($bundle | is-empty)) {
    $bundle
  } else {
    fail $"expected bundle in ($source_label) to be a non-empty string"
  }

  let normalized = {
    name: $repo_name
    path: $repo_path
    bundle: $bundle
    profiles: (expect-optional-string-list ($repo_value | get -o profiles) $source_label "profiles")
    inputs: (expect-optional-string-list ($repo_value | get -o inputs) $source_label "inputs")
    imports: (expect-optional-string-list ($repo_value | get -o imports) $source_label "imports")
  }

  $normalized
}

export def polyrepo-model-from-polyrepo-manifest [manifest_label: string manifest_text: string]: nothing -> oneof<record, error> {
  let manifest = parse-top-level-nuon-mapping $manifest_label $manifest_text
  let repo_dirs_path = ($manifest | get -o repoDirsPath)

  if (($repo_dirs_path | describe) != 'string') or ($repo_dirs_path | is-empty) {
    fail $"expected repoDirsPath in ($manifest_label) to be a non-empty string"
  }

  let inputs_catalog = ($manifest | get -o inputs | default {})
  let bundles_catalog = ($manifest | get -o bundles | default {})
  let profiles_catalog = ($manifest | get -o profiles | default {})
  let repos_catalog = ($manifest | get -o repos | default [])

  if (($inputs_catalog | describe) !~ '^record') {
    fail $"expected inputs in ($manifest_label) to be a mapping"
  }

  if (($bundles_catalog | describe) !~ '^record') {
    fail $"expected bundles in ($manifest_label) to be a mapping"
  }

  if (($profiles_catalog | describe) !~ '^record') {
    fail $"expected profiles in ($manifest_label) to be a mapping"
  }

  if (($repos_catalog | describe) !~ '^(list|table)') {
    fail $"expected repos in ($manifest_label) to be a list"
  }

  let repos = (
    $repos_catalog
    | each {|repo_value| normalize-polyrepo-repo-entry $repo_value $manifest_label }
  )
  let duplicate_repo_names = (
    $repos
    | group-by name
    | transpose name entries
    | where {|group| (($group.entries | length) > 1) }
    | each {|group| $group.name }
    | sort
  )

  if not ($duplicate_repo_names | is-empty) {
    fail $"expected repos in ($manifest_label) to use unique names: ($duplicate_repo_names | str join ', ')"
  }

  {
    repoDirsPath: $repo_dirs_path
    defaultProfiles: (expect-optional-string-list ($manifest | get -o defaultProfiles) $manifest_label "defaultProfiles")
    inputs: (
      $inputs_catalog
      | items {|input_name, input_value|
          [$input_name (normalize-polyrepo-input-entry $input_name $input_value $manifest_label)]
        }
      | into record
    )
    bundles: (
      $bundles_catalog
      | items {|bundle_name, bundle_value|
          [$bundle_name (normalize-polyrepo-overlay-entry "bundles" $bundle_name $bundle_value $manifest_label)]
        }
      | into record
    )
    profiles: (
      $profiles_catalog
      | items {|profile_name, profile_value|
          [$profile_name (normalize-polyrepo-overlay-entry "profiles" $profile_name $profile_value $manifest_label)]
        }
      | into record
    )
    repos: $repos
  }
}

export def repo-dirs-path-from-polyrepo-manifest [manifest_label: string manifest_text: string]: nothing -> oneof<path, error> {
  polyrepo-model-from-polyrepo-manifest $manifest_label $manifest_text | get repoDirsPath
}

export def repo-records-from-polyrepo-manifest [manifest_label: string manifest_text: string]: nothing -> oneof<list<record>, error> {
  polyrepo-model-from-polyrepo-manifest $manifest_label $manifest_text | get repos
}

export def repo-paths-from-polyrepo-manifest [manifest_label: string manifest_text: string]: nothing -> oneof<list<path>, error> {
  repo-records-from-polyrepo-manifest $manifest_label $manifest_text | get path
}
