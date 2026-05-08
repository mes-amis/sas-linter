# frozen_string_literal: true

require "sas_lexer"
require "set"
require "yaml"

require_relative "sas_linter/version"

# Configurable lint engine for SAS source files. Walks the token stream
# produced by `SasLexer::Lexer` and applies a set of pluggable rules.
#
# Each rule is a subclass of `SasLinter::Rule` and is auto-registered when
# its file is required. Use `SasLinter.new(rules: [...])` to constrain the
# rule set, or `SasLinter.from_config(config_hash)` to honor a YAML config.
class SasLinter
  DEFAULT_CONFIG_PATH = "config/lint.yaml"

  Finding = Struct.new(:path, :line, :column, :rule, :message, :severity, keyword_init: true) do
    def to_s
      "#{path}:#{line}:#{column}: [#{rule}] #{message}"
    end
  end

  class Rule
    class << self
      def registry
        @registry ||= {}
      end

      def register(klass)
        id = klass.rule_id
        raise ArgumentError, "Rule #{klass} did not declare a rule_id" if id.nil?

        registry[id] = klass
      end

      def all
        registry.values
      end

      def fetch(id)
        registry.fetch(id.to_sym) do
          raise ArgumentError, "Unknown lint rule: #{id.inspect}. Known: #{registry.keys.join(', ')}"
        end
      end

      def inherited(subclass)
        super
        # Subclasses self-register once they declare an id via `rule_id :foo`.
      end

      def rule_id(value = nil)
        if value
          @rule_id = value.to_sym
          Rule.register(self)
        end
        @rule_id
      end

      def description(value = nil)
        @description = value if value
        @description
      end

      def severity(value = nil)
        @severity = value if value
        @severity || :warning
      end

      # Build a rule instance from a config hash. Subclasses with
      # constructor arguments should override this — the default
      # forwards `autofix:` (the only generic option) and ignores
      # the rest.
      def from_config(opts = {})
        opts = opts.transform_keys(&:to_s)
        kwargs = {}
        kwargs[:autofix] = opts["autofix"] ? true : false if opts.key?("autofix")
        new(**kwargs)
      end

      # Whether this rule can rewrite source to fix the findings it
      # reports. Rules that override `autofix(source)` should also
      # override this to return true.
      def supports_autofix?
        false
      end
    end

    # @param autofix [Boolean] when true and the rule supports
    #   autofixing, the linter will call `#autofix(source)` after
    #   `#check` and write the result back to disk. The default
    #   constructor accepts this kwarg so every rule's `from_config`
    #   can forward it uniformly; rules that don't support autofix
    #   simply ignore it.
    def initialize(autofix: false)
      @autofix = autofix
    end

    attr_reader :autofix
    alias_method :autofix?, :autofix

    # Subclasses must implement check.
    #
    # @param tokens [Array<Hash>] default-channel tokens (no whitespace, no comments)
    # @param path [String] file path used in Finding output
    # @param all_tokens [Array<Hash>, nil] every token from the lexer including
    #   the comment and whitespace channels — supplied for rules that need to
    #   inspect comments. Default-channel rules can ignore this.
    # @param source [String, nil] the raw source text, supplied for rules
    #   that operate at the byte level (e.g. trailing-whitespace).
    def check(_tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
      raise NotImplementedError
    end

    # Override in subclasses that can rewrite source. Return the
    # modified source string. The base implementation is a no-op so
    # rules without autofix can still appear in an autofix-on lint
    # pass without special-casing.
    def autofix(source) # rubocop:disable Lint/UnusedMethodArgument
      source
    end

    protected

    def finding(line:, column:, message:, path:)
      Finding.new(
        path: path,
        line: line,
        column: column,
        rule: self.class.rule_id,
        message: message,
        severity: self.class.severity
      )
    end
  end

  # @param rules [Array<Symbol|Class|Rule>, nil] When nil, every registered
  #   rule runs with default options. Symbols and classes are instantiated
  #   via `Rule#new`; rule instances are used as-is.
  def initialize(rules: nil)
    classes_or_instances =
      if rules.nil?
        Rule.all
      else
        rules
      end

    @rules = classes_or_instances.map do |r|
      case r
      when Rule then r
      when Class then r.new
      else Rule.fetch(r).new
      end
    end
  end

  # Build a linter from a parsed config hash. Schema:
  #
  #   rules:
  #     <rule_id>:
  #       enabled: true|false        # default: true
  #       <option>: <value>           # passed to Rule.from_config
  #
  # Rules omitted from the config default to enabled with no options, so
  # adding a new rule to the gem won't silently disable it for users with
  # an existing config file. To suppress a rule, list it with `enabled: false`.
  def self.from_config(config)
    config = (config || {}).transform_keys(&:to_s)
    rules_config = (config["rules"] || {}).transform_keys(&:to_s)
    instances = []

    rules_config.each do |id, opts|
      opts = (opts || {}).transform_keys(&:to_s)
      next if opts["enabled"] == false

      klass = Rule.fetch(id.to_sym)
      instances << klass.from_config(opts.reject { |k, _| k == "enabled" })
    end

    Rule.all.each do |klass|
      next if rules_config.key?(klass.rule_id.to_s)

      instances << klass.new
    end

    new(rules: instances)
  end

  # Load a YAML config file and return a parsed hash. Returns an empty hash
  # when the file is missing — the default `config/lint.yaml` is optional.
  def self.load_config_file(path)
    return {} unless File.file?(path)

    YAML.safe_load_file(path) || {}
  end

  # Lint a SAS source string. `path` is used for finding location output.
  # Returns just the findings array. Use `lint_with_fixes` when the caller
  # wants the (possibly-modified) source back too.
  def lint(source, path: "(string)")
    lint_with_fixes(source, path: path).first
  end

  # Lint a SAS source string and apply any autofixes from rules whose
  # `autofix?` instance flag is true. Returns `[findings, modified_source]`.
  # When no rule has autofix enabled the modified source equals the input.
  def lint_with_fixes(source, path: "(string)")
    default_tokens, all_tokens = tokenize(source)
    findings = @rules.flat_map do |rule|
      rule.check(default_tokens, path: path, all_tokens: all_tokens, source: source)
    end

    modified = source
    @rules.each do |rule|
      next unless rule.autofix? && rule.class.supports_autofix?

      modified = rule.autofix(modified)
    end

    [findings, modified]
  end

  # Lint a file by path. Sources are commonly Windows-1252 or ISO-8859-1
  # rather than UTF-8 — read as binary and best-effort transcode so
  # the lexer (which requires valid UTF-8) doesn't reject them.
  #
  # If any autofix-enabled rule rewrote the source, the file is updated
  # in place. Returns the findings array regardless of write outcome.
  #
  # The `modified.b != original.b` guard compares raw bytes so a
  # difference in encoding tags alone (e.g. UTF-8 vs ASCII-8BIT)
  # doesn't trigger a write. That can happen when EncodingIssues
  # autofix returns a binary string but no rule actually changed any
  # bytes — without `.b` the file would be rewritten with byte-
  # identical contents and a different encoding label, surfacing as
  # a no-op diff in git that overwrites the user's chosen encoding.
  def lint_file(path)
    original = read_source(path)
    findings, modified = lint_with_fixes(original, path: path)
    File.write(path, modified) if modified.b != original.b
    findings
  end

  # Apply formatting to a file in-place. Runs the formatter's own
  # transformations first, then the autofix pipeline for rules that have
  # `autofix: true` in config — identical to lint_with_fixes except that the
  # formatter pass runs first. Rules that haven't been opted in to autofix
  # (e.g. missing_assignment_semicolon without explicit `autofix: true`) are
  # left alone so that --format stays cosmetic by default.
  #
  # Returns true if the file was rewritten, false if nothing changed.
  def format_file(path, formatter:)
    original = read_source(path)
    modified = formatter.format(original)
    @rules.each do |rule|
      next unless rule.autofix? && rule.class.supports_autofix?

      modified = rule.autofix(modified)
    end
    return false if modified.b == original.b

    File.write(path, modified)
    true
  end

  private

  def read_source(path)
    raw = File.read(path, encoding: "BINARY")
    return raw.force_encoding("UTF-8") if raw.dup.force_encoding("UTF-8").valid_encoding?

    begin
      raw.force_encoding("Windows-1252").encode("UTF-8", invalid: :replace, undef: :replace, replace: "'")
    rescue StandardError
      raw.force_encoding("ISO-8859-1").encode("UTF-8", invalid: :replace, undef: :replace, replace: "'")
    end
  end

  # Returns [default_tokens, all_tokens]. Most rules walk default-channel
  # tokens (no whitespace, no comments). A few — `commented_out_guard` for
  # one — need to inspect comment tokens, so the unfiltered list is exposed
  # to rules via the `all_tokens:` kwarg on `Rule#check`.
  def tokenize(source)
    lexer = SasLexer::Lexer.new
    begin
      all_tokens = lexer.tokenize(source)
    ensure
      lexer.free
    end
    default_tokens = all_tokens.reject do |t|
      t[:channel] == SasLexer::Lexer::TokenChannel::HIDDEN ||
        t[:channel] == SasLexer::Lexer::TokenChannel::COMMENT
    end
    [default_tokens, all_tokens]
  end
end

require_relative "sas_linter/formatter"
require_relative "sas_linter/rules/unreachable_inner_branch_value"
require_relative "sas_linter/rules/identical_if_else_branches"
require_relative "sas_linter/rules/commented_out_guard"
require_relative "sas_linter/rules/choose_one_template"
require_relative "sas_linter/rules/trailing_whitespace"
require_relative "sas_linter/rules/tab_expansion"
require_relative "sas_linter/rules/source_headers"
require_relative "sas_linter/rules/line_endings"
require_relative "sas_linter/rules/encoding_issues"
require_relative "sas_linter/rules/malformed_if_condition"
require_relative "sas_linter/rules/missing_assignment_semicolon"
require_relative "sas_linter/rules/malformed_label_statement"
require_relative "sas_linter/rules/variable_value_out_of_known_range"
require_relative "sas_linter/rules/invalid_numeric_literal"
require_relative "sas_linter/rules/inconsistent_variable_case"
require_relative "sas_linter/rules/format_for_unknown_variable"
require_relative "sas_linter/rules/unterminated_comment"
