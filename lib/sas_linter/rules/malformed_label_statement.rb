# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag `label` statements where the `=` between the variable name
    # and the string literal is missing.
    #
    # Motivating bug: `label aHSDELIRIUM 'Delirium Screener';` in
    # SUITE9_HS_DELIRIUM_SCREENER_2014-04-15.TXT — SAS rejects this
    # with "ERROR 22-322: Syntax error, expecting one of the following:
    # =, ?", and the label is silently never attached. The treatment
    # variant of the same algorithm shipped the same typo, and several
    # other interRAI sources have shipped it over time.
    #
    # Detection: every `label` statement is a `KW_LABEL` keyword
    # followed by one or more `IDENT '=' STRING_LITERAL` triples
    # separated by whitespace, terminated by `;`. We walk each label
    # statement and, for each IDENT inside it, require the next
    # default-channel token to be `ASSIGN` (`=`). If instead the next
    # token is a STRING_LITERAL, the `=` was dropped.
    class MalformedLabelStatement < Rule
      rule_id :malformed_label_statement
      description "`label` statement missing `=` between variable and string literal."
      severity :warning

      TT = SasLexer::Lexer::TokenType

      def self.supports_autofix?
        true
      end

      def check(tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        findings = []
        each_label_violation(tokens) do |ident_t, string_t|
          findings << finding(
            line: ident_t[:start_line],
            column: ident_t[:start_column] + 1,
            message: "`label #{ident_t[:text]} #{shorten(string_t[:text])}` is missing the `=` " \
                     "between the variable name and the label string.",
            path: path
          )
        end
        findings
      end

      def autofix(source)
        return source if source.nil? || source.empty?

        lexer = SasLexer::Lexer.new
        begin
          all_tokens = lexer.tokenize(source)
        ensure
          lexer.free
        end
        tokens = all_tokens.reject do |t|
          t[:channel] == SasLexer::Lexer::TokenChannel::HIDDEN ||
            t[:channel] == SasLexer::Lexer::TokenChannel::COMMENT
        end

        source_lines = source.split("\n", -1)
        # Collect (line_idx, col_after_ident) for each malformed label,
        # then apply edits right-to-left within each line so earlier
        # column offsets stay valid.
        edits_by_line = Hash.new { |h, k| h[k] = [] }

        each_label_violation(tokens) do |ident_t, _string_t|
          edits_by_line[ident_t[:start_line] - 1] << ident_t[:end_column]
        end

        edits_by_line.each do |line_idx, cols|
          line = source_lines[line_idx]
          next if line.nil?

          # Right-to-left so earlier insertions don't shift later columns.
          cols.sort.reverse.each do |col|
            # Insert ` =` immediately after the IDENT (consuming the
            # following space if there is one, preserving alignment).
            replacement =
              if col < line.length && line[col] == " "
                # `aHSDELIRIUM 'Delirium Screener'` → `aHSDELIRIUM = 'Delirium Screener'`.
                # Replace the single space with ` = ` (one space before, one after).
                " = #{line[(col + 1)..]}"
              else
                " = #{line[col..]}"
              end
            line = "#{line[0...col]}#{replacement}"
          end
          source_lines[line_idx] = line
        end

        source_lines.join("\n")
      end

      private

      def each_label_violation(tokens)
        tokens.each_with_index do |t, i|
          next unless t[:type] == TT::KW_LABEL

          # Walk forward through the label statement until SEMI.
          j = i + 1
          while j < tokens.length && tokens[j][:type] != TT::SEMI
            cur = tokens[j]
            if cur[:type] == TT::IDENTIFIER
              nxt = tokens[j + 1]
              if nxt && nxt[:type] == TT::STRING_LITERAL
                yield cur, nxt
                j += 2
                next
              end
            end
            j += 1
          end
        end
      end

      def shorten(text)
        return text if text.nil? || text.length <= 40

        "#{text[0, 37]}..."
      end
    end
  end
end
