# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag identifiers that are spelled with inconsistent letter case
    # across the file. SAS resolves variable references case-insensitively,
    # so `myVar` and `MyVar` end up bound to the same column — but mixing
    # the two within one program is sloppy and makes the source harder to
    # grep, diff, and read.
    #
    # The most-used spelling wins; every other casing is reported (and
    # rewritten when autofix is on). Ties resolve to the first occurrence
    # so the canonical form is reading-order deterministic.
    #
    # Skipped on purpose:
    #   * identifiers immediately followed by `.` (format references like
    #     `agecat.`, library references like `work.foo`);
    #   * identifiers immediately preceded by `.` (the column half of
    #     `lib.member` / `dataset.col`) — those name a column in another
    #     dataset, not a variable in the current step;
    #   * `value` / `invalue` / `picture` themselves and the format name
    #     directly following them — these are proc-format definitions,
    #     not variable references. We match locally rather than tracking
    #     a `proc format ... run;` block because real-world SAS files
    #     meant to be `%include`d into a caller's data step often omit
    #     the terminating `run;`, so a state machine would never close.
    class InconsistentVariableCase < Rule
      rule_id :inconsistent_variable_case
      description "Variable identifiers must use one consistent letter case " \
                  "across the file; mixing `myVar` and `MyVar` is sloppy."
      severity :warning

      TT = SasLexer::Lexer::TokenType

      # Identifiers that introduce a format / informat / picture
      # definition in a `proc format` step. The lexer types these as
      # plain IDENTIFIERs (not keywords), so we recognize them by text.
      FORMAT_DEF_KEYWORDS = %w[value invalue picture].freeze

      def self.supports_autofix?
        true
      end

      def check(tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        findings = []
        each_inconsistent_use(tokens) do |token, canonical|
          findings << finding(
            line: token[:start_line],
            column: token[:start_column] + 1,
            message: "variable `#{token[:text]}` is spelled `#{canonical}` " \
                     "elsewhere in this file — pick one case and stick with it.",
            path: path
          )
        end
        findings
      end

      def autofix(source)
        return source if source.nil? || source.empty?

        # If a previous rule's autofix returned ASCII-8BIT (e.g.
        # EncodingIssues#autofix walks bytes and returns binary), tag
        # it UTF-8 before slicing. The lexer treats the bytes as UTF-8
        # and reports character offsets either way; only Ruby's
        # `String#[]=` cares about the encoding label, and it indexes
        # by bytes for ASCII-8BIT but by characters for UTF-8 — so a
        # binary tag plus any multi-byte sequence earlier in the file
        # would shift every replacement by the byte/char gap.
        src = source.encoding == Encoding::UTF_8 ? source : source.dup.force_encoding("UTF-8")

        lexer = SasLexer::Lexer.new
        begin
          all_tokens = lexer.tokenize(src)
        ensure
          lexer.free
        end
        tokens = all_tokens.reject do |t|
          t[:channel] == SasLexer::Lexer::TokenChannel::HIDDEN ||
            t[:channel] == SasLexer::Lexer::TokenChannel::COMMENT
        end

        edits = []
        each_inconsistent_use(tokens) do |token, canonical|
          edits << [token[:start], token[:end], canonical]
        end

        # Apply right-to-left so earlier offsets stay valid.
        out = src.dup
        edits.sort_by! { |start, _, _| -start }
        edits.each { |start, finish, repl| out[start...finish] = repl }
        out
      end

      private

      # Yields `[token, canonical_form]` for every identifier whose
      # spelling differs from the file-wide canonical case.
      def each_inconsistent_use(tokens)
        groups = collect_variable_uses(tokens)

        groups.each_value do |uses|
          forms = uses.map { |t| t[:text] }.tally
          next if forms.size <= 1

          canonical = canonical_form(forms, uses)
          uses.each do |t|
            yield t, canonical unless t[:text] == canonical
          end
        end
      end

      # Walk default-channel tokens and bucket eligible IDENTIFIER
      # uses by lowercase name. Format-related identifiers (see class
      # docstring) are filtered out by `variable_use?`.
      def collect_variable_uses(tokens)
        groups = Hash.new { |h, k| h[k] = [] }
        tokens.each_with_index do |t, i|
          next unless t[:type] == TT::IDENTIFIER && variable_use?(tokens, i)

          groups[t[:text].downcase] << t
        end
        groups
      end

      # Reject `format.` / `lib.member` shapes via byte-adjacency to a
      # `.` token, and `value <fmt-name>` shapes by checking the
      # neighboring identifier. The lexer emits the dot separately, so
      # we use `prev.end == t.start` / `t.end == nxt.start` to tell a
      # truly-adjacent dot from one that just happens to follow after
      # whitespace.
      def variable_use?(tokens, i)
        t = tokens[i]
        nxt = tokens[i + 1]
        prev = i.positive? ? tokens[i - 1] : nil

        return false if nxt && nxt[:type] == TT::DOT && nxt[:start] == t[:end]
        return false if prev && prev[:type] == TT::DOT && prev[:end] == t[:start]
        return false if FORMAT_DEF_KEYWORDS.include?(t[:text].downcase)
        return false if prev && prev[:type] == TT::IDENTIFIER &&
                        FORMAT_DEF_KEYWORDS.include?(prev[:text].downcase)

        true
      end

      # Most-used spelling wins; ties go to the first occurrence so the
      # canonical form matches reading order and stays deterministic
      # across runs.
      def canonical_form(forms, uses)
        max_count = forms.values.max
        winners = forms.select { |_, c| c == max_count }.keys
        return winners.first if winners.size == 1

        uses.each { |t| return t[:text] if winners.include?(t[:text]) }
        winners.first
      end
    end
  end
end
