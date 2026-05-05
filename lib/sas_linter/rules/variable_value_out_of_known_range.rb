# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"
require "csv"

class SasLinter
  module Rules
    # Flag conditional comparisons against literal values that fall outside a
    # variable's documented acceptable values, e.g.:
    #
    #     if AGE in (0,1,2,99) then ...   # AGE takes 0..2 — `99` is dead
    #     if SCORE = 99 then ...          # SCORE takes 0..5
    #     if RANK eq 7 then ...           # RANK takes 0..6
    #
    # Catches typos and stale literals where the source compares a variable
    # against a value the variable can never actually take, so the branch is
    # unreachable. Only fires inside `if`-conditions (between KW_IF and the
    # next KW_THEN or SEMI) — assignments to the variable are not flagged.
    #
    # Acceptable values are loaded from one or more CSV files with two
    # configurable columns: a name column and an acceptable-values column.
    # Recognized value formats:
    #
    #     0-5                      → integer range
    #     1,2,3                    → integer set
    #     0-4,7,8                  → range plus extras
    #     0-90 (99)                → range plus parenthesized extras
    #
    # Variables whose values column is free text or a date pattern are
    # silently skipped (no findings, no errors).
    #
    # Recognized config options:
    #     csv_paths:     ["metadata/variables.csv", ...]   # required, at least one
    #     name_column:   "Variable"                        # default: "Variable"
    #     values_column: "Acceptable Values"               # default: "Acceptable Values"
    #     name_match:    case_insensitive | exact          # default: case_insensitive
    #     autofix:       false                             # this rule has no autofix
    #
    # When `csv_paths` is empty the rule is a no-op — useful so projects
    # without a variable catalog can keep the rule registered without it
    # firing.
    class VariableValueOutOfKnownRange < Rule
      rule_id :variable_value_out_of_known_range
      description "Comparison literal falls outside a variable's documented " \
                  "acceptable values — branch is unreachable."
      severity :warning

      TT = SasLexer::Lexer::TokenType

      DEFAULT_NAME_COLUMN = "Variable"
      DEFAULT_VALUES_COLUMN = "Acceptable Values"
      DEFAULT_DELIMITER = ","

      def initialize(csv_paths: [],
                     name_column: DEFAULT_NAME_COLUMN,
                     values_column: DEFAULT_VALUES_COLUMN,
                     name_match: :case_insensitive,
                     delimiter: DEFAULT_DELIMITER,
                     autofix: false)
        super(autofix: autofix)
        @csv_paths = Array(csv_paths)
        @name_column = name_column
        @values_column = values_column
        @delimiter = delimiter
        unless %i[case_insensitive exact].include?(name_match)
          raise ArgumentError, "name_match must be :case_insensitive or :exact (got #{name_match.inspect})"
        end

        @name_match = name_match
        @specs = nil
      end

      def self.from_config(opts = {})
        opts = opts.transform_keys(&:to_s)
        new(
          csv_paths: Array(opts["csv_paths"]).map { |p| File.expand_path(p) },
          name_column: opts["name_column"] || DEFAULT_NAME_COLUMN,
          values_column: opts["values_column"] || DEFAULT_VALUES_COLUMN,
          name_match: (opts["name_match"] || "case_insensitive").to_sym,
          delimiter: opts["delimiter"] || DEFAULT_DELIMITER,
          autofix: opts["autofix"] ? true : false
        )
      end

      def check(tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        return [] if specs.empty?

        findings = []
        in_condition = false
        i = 0

        while i < tokens.length
          tok = tokens[i]

          case tok[:type]
          when TT::KW_IF
            in_condition = true
            i += 1
            next
          when TT::KW_THEN, TT::SEMI
            in_condition = false
            i += 1
            next
          end

          if in_condition && tok[:type] == TT::IDENTIFIER
            op = tokens[i + 1]
            if op
              consumed, ident_findings = check_comparison(tokens, i, tok, op, path)
              findings.concat(ident_findings)
              if consumed > 0
                i += consumed
                next
              end
            end
          end

          i += 1
        end

        findings
      end

      private

      # Returns [tokens_consumed, findings]. consumed=0 if no recognized
      # comparison started here.
      def check_comparison(tokens, ident_idx, ident, op, path)
        spec = lookup_spec(ident[:text])
        return [0, []] unless spec

        case op[:type]
        when TT::KW_IN
          lparen = tokens[ident_idx + 2]
          return [0, []] unless lparen && lparen[:type] == TT::LPAREN

          findings = []
          k = ident_idx + 3
          while k < tokens.length
            t = tokens[k]
            break unless t

            if t[:type] == TT::RPAREN
              return [k - ident_idx + 1, findings]
            elsif t[:type] == TT::COMMA
              k += 1
              next
            end

            lit = literal_value(t)
            if lit && !value_allowed?(spec, lit[:value])
              findings << finding(
                line: t[:start_line],
                column: t[:start_column] + 1,
                message: format_message(ident[:text], lit[:display], spec),
                path: path
              )
            end
            k += 1
          end

          [k - ident_idx + 1, findings]
        when TT::KW_EQ, TT::ASSIGN
          lit_tok = tokens[ident_idx + 2]
          lit = literal_value(lit_tok)
          return [0, []] unless lit
          return [3, []] if value_allowed?(spec, lit[:value])

          [3, [finding(
            line: lit_tok[:start_line],
            column: lit_tok[:start_column] + 1,
            message: format_message(ident[:text], lit[:display], spec),
            path: path
          )]]
        else
          [0, []]
        end
      end

      def lookup_spec(text)
        key = @name_match == :exact ? text : text.downcase
        specs[key]
      end

      def specs
        @specs ||= load_specs
      end

      def load_specs
        map = {}
        @csv_paths.each do |path|
          next unless File.file?(path)

          CSV.foreach(path, headers: true, col_sep: @delimiter) do |row|
            name = row[@name_column]
            values_text = row[@values_column]
            next if name.nil? || name.strip.empty?
            next if values_text.nil? || values_text.strip.empty?

            spec = parse_values(values_text.strip)
            next unless spec

            key = @name_match == :exact ? name : name.downcase
            map[key] = spec
          end
        end
        map
      end

      # Recognized value-string formats. Anything else (free text, date
      # patterns, alpha ranges) returns nil and the row is skipped.
      def parse_values(text)
        case text
        when /\A(-?\d+)-(-?\d+)\z/
          { type: :range, in: ($1.to_i)..($2.to_i) }
        when /\A-?\d+(?:\s*,\s*-?\d+)+\z/
          { type: :set, in: text.split(/\s*,\s*/).map(&:to_i) }
        when /\A(\d+)-(\d+)\s+\(([^)]+)\)\z/
          base = ($1.to_i)..($2.to_i)
          extras = Regexp.last_match(3).split(/\s*,\s*/).map { |x| Integer(x) rescue nil }.compact
          { type: :set, in: base.to_a + extras }
        when /\A(\d+)-(\d+)\s*,\s*(.+)\z/
          base = ($1.to_i)..($2.to_i)
          extras = Regexp.last_match(3).split(/\s*,\s*/).map { |x| Integer(x) rescue nil }.compact
          return nil if extras.empty?

          { type: :set, in: base.to_a + extras }
        end
      end

      def value_allowed?(spec, value)
        allowed = spec[:in]
        return true if allowed.nil?

        case spec[:type]
        when :range
          allowed.cover?(value)
        when :set
          allowed.include?(value)
        else
          true
        end
      end

      def literal_value(tok)
        return nil unless tok

        case tok[:type]
        when TT::INTEGER_LITERAL
          n = begin
            Integer(tok[:text])
          rescue StandardError
            return nil
          end
          { value: n, display: tok[:text] }
        when TT::FLOAT_LITERAL
          f = begin
            Float(tok[:text])
          rescue StandardError
            return nil
          end
          { value: (f == f.to_i ? f.to_i : f), display: tok[:text] }
        when TT::STRING_LITERAL
          { value: tok[:text].gsub(/\A['"]|['"]\z/, ""), display: tok[:text] }
        end
      end

      def format_message(ident, display, spec)
        allowed_str =
          case spec[:type]
          when :range then spec[:in].to_s
          when :set then "{#{spec[:in].join(', ')}}"
          end
        "value #{display} for #{ident} is outside the documented acceptable " \
          "values (#{allowed_str}); this branch is unreachable."
      end
    end
  end
end
