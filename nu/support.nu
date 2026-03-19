export def fail [message: string]: nothing -> error {
  error make --unspanned $message
}

export def is-record [value: any]: nothing -> bool {
  ($value | describe) =~ '^record'
}

export def is-list [value: any]: nothing -> bool {
  ($value | describe) =~ '^list'
}

export def is-string [value: any]: nothing -> bool {
  ($value | describe) == 'string'
}

export def is-nothing [value: any]: nothing -> bool {
  ($value | describe) == 'nothing'
}

export def is-non-empty-string [value: any]: nothing -> bool {
  (is-string $value) and ($value | is-not-empty)
}

export def polyrepo-manifest-basename []: nothing -> string {
  "polyrepo.nuon"
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
