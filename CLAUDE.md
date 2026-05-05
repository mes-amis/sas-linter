# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
bundle install                                  # install dev deps
bundle exec rake spec                           # full test suite (also `rake` default)
bundle exec rspec spec/sas_linter_spec.rb       # single file
bundle exec rspec spec/sas_linter_spec.rb:42    # single example by line
bundle exec rubocop                             # lint Ruby (also `rake rubocop`)
bin/sas_lint --list-rules                       # CLI sanity check (lists every registered rule)
bin/sas_lint path/to/file.sas                   # run linter from working tree
gem build sas-linter.gemspec                    # build the gem locally
```

Ruby ≥ 3.4 is required (see gemspec). CI matrix runs ubuntu + macOS on Ruby 3.4 and 4.0.

## Architecture

**Rule registry, self-registering subclasses.** `SasLinter::Rule` keeps a class-level `registry` keyed by rule id. Subclasses call `rule_id :foo` in their class body, which triggers `Rule.register(self)`. Requiring a rule file is enough to make it discoverable via `SasLinter::Rule.fetch(:foo)` and to include it in `SasLinter.new` (no rules arg → all registered rules). All rule files are required at the bottom of `lib/sas_linter.rb`; new rules must be added to that require block.

**Two-channel token stream.** `SasLinter#tokenize` runs `SasLexer::Lexer` once and returns `[default_tokens, all_tokens]`. Default-channel excludes whitespace + comment tokens; `all_tokens` keeps everything. `Rule#check(tokens, path:, all_tokens:, source:)` receives both, plus the raw `source` string. Most rules walk default-channel only; `commented_out_guard` needs comments, source-hygiene rules (`trailing_whitespace`, `tab_expansion`, `line_endings`, `encoding_issues`, `source_headers`) work directly on `source`.

**Config-driven instantiation.** `SasLinter.from_config(hash)` walks `config["rules"]`, skips `enabled: false` entries, and calls `klass.from_config(opts)` on the rest. The base `Rule.from_config` only forwards `autofix:` — rules with extra options (`encoding_issues`, `tab_expansion`, `variable_value_out_of_known_range`) override `from_config` to map their YAML keys onto kwargs. **Rules omitted from a config default to enabled with no options** so adding a new rule never silently disables it for existing users; to suppress, list with `enabled: false`.

**Autofix pipeline.** `lint_with_fixes` returns `[findings, modified_source]`. After `check`, the engine runs `autofix(source)` on every rule where `rule.autofix?` (instance flag from config) AND `rule.class.supports_autofix?` (class capability) are both true. Autofixes compose by chaining each rule's output into the next rule's input. `lint_file` writes the result back **only if `modified.b != original.b`** — the `.b` byte compare prevents spurious rewrites when a rule returns a re-encoded but byte-identical string (encoding-tag-only diffs would otherwise overwrite the user's encoding). The CLI's `--no-autofix` strips `autofix: true` from the loaded config hash *before* constructing the linter, so a dry run cannot rewrite a file even if the config requests it.

**Source encoding fallback.** SAS sources are commonly Windows-1252 or ISO-8859-1. `read_source` reads as BINARY, returns as UTF-8 if already valid, otherwise transcodes Win-1252 → UTF-8 with `invalid: :replace, undef: :replace, replace: "'"`, falling back to ISO-8859-1 on failure. The lexer requires valid UTF-8, so this transcode happens before tokenization.

**Custom rules.** Subclass `SasLinter::Rule`, declare `rule_id`, `description`, `severity`, implement `check`. To support autofix, override `self.supports_autofix?` to return true and implement `#autofix(source)` returning the rewritten source. Use the protected `finding(line:, column:, message:, path:)` helper rather than building `Finding` structs directly so severity and rule id are filled in consistently.

## Test fixtures

`spec/sas_linter_spec.rb` is the integration suite. Per-rule fixtures live in `spec/fixtures/lints/<rule_id>/` as a pair: `lint.sas` (demonstrates the bug, expected to produce findings) and `clean.sas` (same shape, fixed, expected to be silent). Helpers `lint_fixture(name)` and `clean_fixture(name)` resolve those paths. When adding a rule, add a matching fixture pair — the suite's parametric tests rely on the convention. Rule-specific unit specs live under `spec/sas_linter/rules/`.

## Release flow

`.github/workflows/publish.yml` publishes to RubyGems on push to `main` via OIDC trusted publishing (no API key in repo). The job is idempotent: it checks for an existing `v<version>` tag on origin and treats RubyGems "already pushed" responses as success. To cut a release, bump `SasLinter::VERSION` in `lib/sas_linter/version.rb` and merge to `main`; the workflow tags `v<version>` and creates a GitHub release.

## License note

AGPL-3.0-or-later — chosen to match upstream `sas-lexer`. Redistribution and network-service use trigger source-disclosure obligations; standalone CLI/CI use does not. Keep this in mind before suggesting embedding the linter into a redistributed product.
