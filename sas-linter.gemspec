# frozen_string_literal: true

require_relative "lib/sas_linter/version"

Gem::Specification.new do |spec|
  spec.name = "sas-linter"
  spec.version = SasLinter::VERSION
  spec.authors = ["Craig McNamara"]
  spec.email = ["craig@monami.io"]

  spec.summary = "Configurable lint engine for SAS source files."
  spec.description = <<~DESC
    A configurable lint engine for SAS source files. Walks the token
    stream produced by the `sas-lexer` gem and applies a set of pluggable
    rules covering structural defects (malformed `if` conditions,
    identical `then`/`else` branches, unreachable inner branches),
    cosmetic issues (trailing whitespace, tab expansion, line endings,
    encoding gremlins), and source-header conventions. Includes a
    `bin/sas_lint` CLI and YAML-based config.
  DESC
  spec.homepage = "https://github.com/mes-amis/sas-linter"
  spec.license = "AGPL-3.0-or-later"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "bin"
  spec.executables = spec.files.grep(%r{\Abin/}).map { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "sas-lexer", "~> 0.1"

  # csv was removed from Ruby's default gems in 3.4; declared explicitly
  # so the variable_value_out_of_known_range rule can read its catalog.
  spec.add_dependency "csv"
end
