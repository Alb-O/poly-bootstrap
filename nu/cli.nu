use support.nu [fail]

export def parse-repeatable-sync-flags [args: list<string>] {
  mut include_repos = []
  mut exclude_repos = []
  mut include_inputs = []
  mut exclude_inputs = []
  mut index = 0

  while $index < ($args | length) {
    let arg = ($args | get $index)

    match $arg {
      "--include-repo" | "-i" => {
        $index = ($index + 1)
        if $index >= ($args | length) {
          fail $"($arg) requires a value"
        }
        $include_repos = ($include_repos | append ($args | get $index))
      }
      "--exclude-repo" | "-x" => {
        $index = ($index + 1)
        if $index >= ($args | length) {
          fail $"($arg) requires a value"
        }
        $exclude_repos = ($exclude_repos | append ($args | get $index))
      }
      "--include-input" | "-I" => {
        $index = ($index + 1)
        if $index >= ($args | length) {
          fail $"($arg) requires a value"
        }
        $include_inputs = ($include_inputs | append ($args | get $index))
      }
      "--exclude-input" | "-X" => {
        $index = ($index + 1)
        if $index >= ($args | length) {
          fail $"($arg) requires a value"
        }
        $exclude_inputs = ($exclude_inputs | append ($args | get $index))
      }
      _ => {
        fail $"unknown sync flag: ($arg)"
      }
    }

    $index = ($index + 1)
  }

  {
    include_repos: ($include_repos | uniq)
    exclude_repos: ($exclude_repos | uniq)
    include_inputs: ($include_inputs | uniq)
    exclude_inputs: ($exclude_inputs | uniq)
  }
}
