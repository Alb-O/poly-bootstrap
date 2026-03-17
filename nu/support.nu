export def fail [message: string]: nothing -> error {
  error make --unspanned $message
}

export def global-inputs-basename []: nothing -> string {
  ".devenv-global-inputs.yaml"
}

export def fail-on-overlap [first_names: list<string> second_names: list<string> first_label: string second_label: string]: nothing -> oneof<nothing, error> {
  let overlap = (
    $first_names
    | where {|name| $name in $second_names }
    | uniq
    | sort
  )

  if not ($overlap | is-empty) {
    fail $"($first_label) and ($second_label) must not overlap: ($overlap | str join ', ')"
  }
}

export def sort-record [value: record]: nothing -> record {
  $value
  | columns
  | sort
  | each {|column| [$column ($value | get $column)] }
  | into record
}
