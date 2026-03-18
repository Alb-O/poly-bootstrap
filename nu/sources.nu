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

def expect-optional-imports [value: any source_label: string]: nothing -> oneof<list<string>, error> {
  if (($value | describe) == 'nothing') {
    return []
  }

  if (($value | describe) !~ '^list') {
    fail $"expected imports in ($source_label) to be a list"
  }

  $value
  | each {|item|
      if (($item | describe) != 'string') or ($item | is-empty) {
        fail $"expected imports in ($source_label) to be non-empty strings"
      }

      $item
    }
}

def normalize-shared-input-entry [input_name: string input_value: any manifest_label: string]: nothing -> oneof<record, error> {
  let source_label = $"sharedInputs.($input_name) in ($manifest_label)"

  match ($input_value | describe) {
    "string" => {
      if ($input_value | is-empty) {
        fail $"expected ($source_label) to be a non-empty string or mapping"
      }

      {
        spec: $input_value
        imports: []
      }
    }
    $t if $t =~ '^record' => {
      let entry_spec = if "imports" in ($input_value | columns) {
        $input_value | reject imports
      } else {
        $input_value
      }

      {
        spec: $entry_spec
        imports: (expect-optional-imports ($input_value | get -o imports) $source_label)
      }
    }
    _ => {
      fail $"expected ($source_label) to be a non-empty string or mapping"
    }
  }
}

export def render-shared-inputs-yaml [manifest_label: string manifest_text: string]: nothing -> oneof<string, error> {
  let manifest = parse-top-level-nuon-mapping $manifest_label $manifest_text
  let shared_inputs = ($manifest | get -o sharedInputs | default {})
  let shared_imports = ($manifest | get -o sharedImports | default [])

  if (($shared_inputs | describe) !~ '^record') {
    fail $"expected sharedInputs in ($manifest_label) to be a mapping"
  }

  let shared_imports = expect-optional-imports $shared_imports $manifest_label
  mut rendered_inputs = {}
  mut rendered_imports = $shared_imports

  for input_name in ($shared_inputs | columns) {
    let entry = normalize-shared-input-entry $input_name ($shared_inputs | get $input_name) $manifest_label
    $rendered_inputs = ($rendered_inputs | merge { $input_name: $entry.spec })
    $rendered_imports = ($rendered_imports | append $entry.imports)
  }

  if (($rendered_inputs | columns | is-empty) and ($rendered_imports | is-empty)) {
    return ""
  }

  mut rendered = {}

  if not ($rendered_inputs | columns | is-empty) {
    $rendered = ($rendered | merge { inputs: $rendered_inputs })
  }

  let rendered_imports = ($rendered_imports | uniq)
  if not ($rendered_imports | is-empty) {
    $rendered = ($rendered | merge { imports: $rendered_imports })
  }

  $rendered | to yaml
}
