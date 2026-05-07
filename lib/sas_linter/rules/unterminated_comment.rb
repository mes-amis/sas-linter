# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag a `** ... **` comment line whose missing `;` causes the
    # SAS lexer to extend the comment statement into the following
    # line(s) of real code, silently swallowing it.
    #
    # SAS `*` / `**` comment statements are terminated by the next
    # `;` — the closing `**` is just prose. So
    #
    #     ** SOME COMMENT **
    #     y = x + 1;
    #
    # lexes as a single comment token covering both lines, and the
    # `y = x + 1;` assignment never executes.
    #
    # Detection: a COMMENT-channel `PREDICTED_COMMENT_STAT` token
    # whose `start_line != end_line` AND whose first source line,
    # rstripped, ends with `**`. That shape is the boxed-comment
    # closer the user clearly intended — they only forgot the `;`.
    # Legitimate multi-line `*...;` prose ends its first line with
    # plain text, not `**`, so it's left alone.
    #
    # Autofix: append `;` to the end of each flagged first line.
    class UnterminatedComment < Rule
      rule_id :unterminated_comment
      description "`**` comment missing its terminating `;` — consumes following code."
      severity :warning

      TT = SasLexer::Lexer::TokenType
      COMMENT_CHANNEL = SasLexer::Lexer::TokenChannel::COMMENT

      def self.supports_autofix?
        true
      end

      def check(_tokens, path:, all_tokens: nil, source: nil)
        return [] unless all_tokens && source

        lines = source.split("\n", -1)
        unterminated_comment_lines(all_tokens, lines).map do |i|
          finding_for_line(lines[i], i, path)
        end
      end

      def autofix(source)
        return source if source.nil? || source.empty?

        lines = source.split("\n", -1)
        bad = unterminated_comment_lines(tokenize(source), lines)
        return source if bad.empty?

        bad.each do |i|
          lines[i] = "#{lines[i].rstrip};"
        end
        lines.join("\n")
      end

      private

      def finding_for_line(line, idx, path)
        finding(
          line: idx + 1,
          column: line.length - line.lstrip.length + 1,
          message: "`**` comment missing `;` — consumes the next line of code as comment text.",
          path: path
        )
      end

      def tokenize(source)
        lexer = SasLexer::Lexer.new
        begin
          lexer.tokenize(source)
        ensure
          lexer.free
        end
      end

      # 0-indexed source lines that hold a `** ... **` comment whose
      # missing `;` made the lexer extend it into the next line.
      def unterminated_comment_lines(all_tokens, lines)
        bad = []
        all_tokens.each do |t|
          next unless t[:channel] == COMMENT_CHANNEL
          next unless t[:type] == TT::PREDICTED_COMMENT_STAT
          next unless t[:start_line] < t[:end_line]

          first = lines[t[:start_line] - 1] or next
          next unless first.rstrip.end_with?("**")

          bad << (t[:start_line] - 1)
        end
        bad
      end
    end
  end
end
