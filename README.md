# sas-linter

A configurable lint engine for SAS source files. Built on the [`sas-lexer`](https://github.com/mes-amis/sas-lexer-rb) gem (a Ruby FFI binding to Misha Perlov's Rust [`sas-lexer`](https://github.com/mishamsk/sas-lexer)) and ships with fourteen pluggable rules covering structural defects, cosmetic issues, and source-header conventions.

## Installation

Add to your Gemfile:

```ruby
gem "sas-linter"
```

Or install directly:

```sh
gem install sas-linter
```

## CLI usage

```sh
# Run every rule on a single file
bin/sas_lint path/to/source.sas

# List all registered rules with their description and autofix capability
bin/sas_lint --list-rules

# Run only specific rules
bin/sas_lint --rules malformed_if_condition,identical_if_else_branches src/*.sas

# Use a YAML config (default: config/lint.yaml)
bin/sas_lint --config my-lint.yaml src/*.sas

# Lint without applying any autofixes the config requested
bin/sas_lint --no-autofix src/*.sas
```

Exit codes: `0` clean, `1` findings, `2` invalid args.

## YAML config

Every rule with options, plus its defaults. Rules omitted from the config default to enabled with no options, so adding a new rule to the gem won't silently disable it for users with existing configs. To suppress a rule, list it with `enabled: false`.

```yaml
rules:
  # ── Structural / semantic rules ─────────────────────────────────────
  unreachable_inner_branch_value:
    enabled: true              # default for every rule

  identical_if_else_branches:
    enabled: true

  malformed_if_condition:
    enabled: true

  commented_out_guard:
    enabled: true

  choose_one_template:
    enabled: true

  missing_assignment_semicolon:
    enabled: true
    autofix: false             # rule supports autofix; off by default

  inconsistent_variable_case:
    enabled: true
    autofix: false             # rewrite every minority casing to the most-common form

  format_for_unknown_variable:
    enabled: true              # skipped automatically when the file uses set/merge/update/infile/input

  variable_value_out_of_known_range:
    enabled: true
    csv_paths:                          # empty list = rule is a no-op
      - metadata/variables.csv
      - metadata/variables-extra.csv
    name_column: "Variable"             # default
    values_column: "Acceptable Values"  # default
    name_match: case_insensitive        # case_insensitive | exact
    delimiter: ","                      # CSV column separator: "," | ";" | "\t"

  # ── Source-hygiene rules (all support autofix) ──────────────────────
  trailing_whitespace:
    enabled: true
    autofix: false

  tab_expansion:
    enabled: true
    autofix: false
    width: 8                   # tab stop width

  source_headers:
    enabled: true
    autofix: false             # rewrap **…**; 90-char header rows when true

  line_endings:
    enabled: true
    autofix: false             # collapse \r\r\n → \r\n; lone \r → dominant ending

  encoding_issues:
    enabled: true
    autofix: false
    use_defaults: false        # apply built-in smart-quote / em-dash / Win-1252 map
    replacements:              # project-specific byte→ASCII rewrites (run BEFORE defaults)
      "—": "--"
      "\x85": "Ö"
```

`enabled` and `autofix` are accepted on every rule. Options not listed above are ignored.

## Library usage

```ruby
require "sas_linter"

linter = SasLinter.new                                    # all registered rules
linter = SasLinter.new(rules: [:malformed_if_condition])  # subset by rule id
linter = SasLinter.from_config(YAML.load_file("lint.yaml"))

findings = linter.lint(source_string, path: "demo.sas")
findings.each { |f| puts f.to_s }   # path:line:col: [rule_id] message

# Lint a file. If any rule has autofix enabled and changed the source,
# the file is rewritten in place.
findings = linter.lint_file("path/to/source.sas")
```

## Built-in rules

| rule id | description |
|---|---|
| `unreachable_inner_branch_value` | Outer `if VAR in (S) then do;` guards an inner branch whose comparison values aren't all in `S`. |
| `identical_if_else_branches` | `if COND then S; else S;` with identical bodies — almost always a copy-paste error. |
| `commented_out_guard` | SAS line-comment `* if ... then do;` pattern indicating a disabled outer validity guard. |
| `choose_one_template` | `** CHOOSE ONE OF THE BELOW STATEMENTS;` banner indicating a broken-by-default source. |
| `trailing_whitespace` | Trailing spaces/tabs at end of line. |
| `tab_expansion` | Tab characters that should be spaces (configurable width). |
| `source_headers` | Restore the `**...**;` 90-char header convention to broken sources. |
| `line_endings` | Mixed or non-CRLF line terminators (configurable target). |
| `encoding_issues` | Smart-quote / em-dash / Win-1252 byte sequences that confuse downstream tooling. |
| `malformed_if_condition` | Empty conditions, missing operators, orphan `then`, unbalanced parens, etc. |
| `missing_assignment_semicolon` | Assignment statements followed by an inline `**` comment but no terminating `;`. |
| `variable_value_out_of_known_range` | `if VAR = N` / `if VAR in (...)` literals fall outside the variable's documented acceptable values. Loads the catalog from one or more CSVs with configurable column names and column separator (`,`, `;`, tab). |
| `inconsistent_variable_case` | Identifier appears with more than one casing in the same file (`myVar` vs `MyVar`). SAS treats both as the same variable; autofix rewrites every minority spelling to the most-common form. Skips proc-format definitions and `format.` / `lib.member` references. |
| `format_for_unknown_variable` | `format` / `informat` / `attrib` statement assigns a format to a variable that's referenced nowhere else in the file — almost always a typo. Skipped on files that pull in columns via `set` / `merge` / `update` / `infile` / `input`. |

`bin/sas_lint --list-rules` prints the same set with autofix capability.

## Writing a custom rule

Subclass `SasLinter::Rule`, declare an id, description, and severity, then implement `#check`:

```ruby
class MyRule < SasLinter::Rule
  rule_id :my_rule
  description "Flag occurrences of FOO in DATA steps."
  severity :warning

  def check(tokens, path:, all_tokens: nil, source: nil)
    findings = []
    tokens.each do |t|
      next unless t[:text] == "FOO"
      findings << finding(line: t[:start_line], column: t[:start_column],
                          message: "FOO is forbidden", path: path)
    end
    findings
  end
end
```

Subclasses self-register on the rule registry via `rule_id` — once required, they're picked up by `SasLinter.new` (no rule list) and resolvable via `SasLinter::Rule.fetch(:my_rule)`.

To support autofix, override `self.supports_autofix?` to return `true` and implement `#autofix(source)` to return the rewritten source.

## Testing

```sh
bundle install
bundle exec rake spec
```

## License

[GNU Affero General Public License v3.0 or later](LICENSE) — chosen to match the upstream `sas-lexer` gem (which `sas-linter` requires at runtime). © Mon Ami, Inc.

Practical implications:

- **Internal / personal use** has no obligations beyond preserving notices.
- **Redistribution** (shipping the gem inside a binary, container image, or product) requires offering the complete corresponding source under AGPL-3.0.
- **Network use** (running `sas-linter` as a backend that users interact with remotely) triggers the AGPL's source-disclosure clause for those network users.
- **Combined works** with `sas-linter` must be licensed under AGPL-compatible terms.

If those terms don't fit your use case, run a standalone lint job (CLI / CI step) instead of embedding the linter in a redistributed product.
