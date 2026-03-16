use support.nu [fail]

def normalize-yaml-value [value: any] {
  match ($value | describe) {
    $t if $t =~ '^record' => {
      $value
      | items {|key, item| [$key (normalize-yaml-value $item)] }
      | into record
    }
    $t if $t =~ '^list' => { $value | each {|item| normalize-yaml-value $item } }
    _ => { $value }
  }
}

export def parse-top-level-mapping [source_label: string yaml_text: string] {
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

  normalize-yaml-value $parsed
}

export def get-inputs-block [source_label: string yaml_text: string] {
  let parsed = parse-top-level-mapping $source_label $yaml_text
  let inputs_block = ($parsed | get -o inputs | default {})

  if (($inputs_block | describe) !~ '^record') {
    fail $"expected `inputs` to be a mapping in ($source_label)"
  }

  $inputs_block
}

export def get-input-names [source_label: string yaml_text: string] {
  get-inputs-block $source_label $yaml_text | columns
}

export def get-imports-list [source_label: string yaml_text: string] {
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

export def read-input-spec [input_spec: any] {
  match ($input_spec | describe) {
    $t if $t =~ '^record' => {
      let url = ($input_spec | get -o url)

      if (($url | describe) == 'string') and (not ($url | is-empty)) {
        {
          url: $url
          spec: $input_spec
        }
      } else {
        null
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

export def parse-json-record [json_path: string message: string] {
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

export def expect-string-list [value: any field_label: string] {
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

export def expect-string-record [value: any field_label: string] {
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
