# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag assignment statements whose terminating `;` is missing,
    # causing the inline `**`-style comment marker to be lexed as
    # the SAS exponentiation operator and absorbed into the RHS
    # expression.
    #
    # The motivating bug is in MDS2.0_CAP_FEEDTB_G2_V2.1_P_2012-03-15.txt:
    #
    #     B1 = B1     **  Comatose;        ← missing `;` before `**`
    #     B4 = B4;    **  Daily decision-making;
    #     K5b = K5b;  **  Tube feeding;
    #
    # SAS lexes the first line as `B1 := B1 ^ Comatose`, where
    # `Comatose` is an undefined variable — the assignment silently
    # produces a missing value at runtime instead of the identity
    # mapping the author intended.
    #
    # Detection: a STAR2 (`**`) token where
    #   * the line containing it does NOT start with `**` (which
    #     would put us in a header / boxed-comment context, where
    #     `**` is part of the comment-statement opener, not an
    #     operator); AND
    #   * the previous default-channel token is an IDENTIFIER (the
    #     RHS variable in the assignment); AND
    #   * the next default-channel token is an IDENTIFIER (the prose
    #     start of what should have been an inline comment).
    #
    # Legitimate `X = Y ** 2` exponentiation has a numeric literal
    # after the `**`, not an identifier, so it doesn't match.
    class MissingAssignmentSemicolon < Rule
      rule_id :missing_assignment_semicolon
      description "Assignment missing terminating `;` — the inline " \
                  "`**` comment marker was lexed as exponentiation."
      severity :warning

      TT = SasLexer::Lexer::TokenType

      def self.supports_autofix?
        true
      end

      def check(tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        findings = []
        lines = (source || "").split("\n", -1)

        tokens.each_with_index do |t, i|
          next unless t[:type] == TT::STAR2

          # Skip header / boxed-comment lines: `** PROGRAM: ... **;`,
          # `**  DATA STEP STARTS HERE  **;`, etc. The `**` there is
          # part of the comment shape, not an operator.
          line = lines[t[:start_line] - 1]
          next if line.nil? || line.lstrip.start_with?("**")

          prev_t = tokens[i - 1] if i.positive?
          next_t = tokens[i + 1]
          next unless prev_t && next_t
          next unless prev_t[:type] == TT::IDENTIFIER && next_t[:type] == TT::IDENTIFIER

          findings << finding(
            line: t[:start_line],
            column: t[:start_column] + 1,
            message: "`**` parsed as exponentiation in `#{prev_t[:text]} ** #{next_t[:text]}` — " \
                     "looks like a missing `;` before an inline `** ... ;` comment.",
            path: path
          )
        end

        findings
      end

      # Insert the missing `;` immediately after the RHS identifier on
      # each flaggable line. By replacing the single space that
      # already sits between the identifier and the `**`, we preserve
      # the existing column alignment of the inline-comment block —
      # the row goes from `B1 = B1     **  ...;` to
      # `B1 = B1;    **  ...;`, matching the canonical SAS
      # `VAR = VAR;   ** description;` shape.
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
        edits = []

        tokens.each_with_index do |t, i|
          next unless t[:type] == TT::STAR2

          line = source_lines[t[:start_line] - 1]
          next if line.nil? || line.lstrip.start_with?("**")

          prev_t = tokens[i - 1] if i.positive?
          next_t = tokens[i + 1]
          next unless prev_t && next_t
          next unless prev_t[:type] == TT::IDENTIFIER && next_t[:type] == TT::IDENTIFIER

          edits << [t[:start_line] - 1, prev_t[:end_column]]
        end

        edits.each do |line_idx, col|
          line = source_lines[line_idx]
          replacement =
            if col + 1 < line.length && line[col] == " " && line[col + 1] == " "
              # Two or more spaces between IDENT and `**`: consume one
              # for the `;` so existing column alignment of the inline
              # `**` comment is preserved (`B1 = B1     **` becomes
              # `B1 = B1;    **`).
              ";#{line[(col + 1)..]}"
            elsif col < line.length && line[col] == " "
              # Exactly one space: keep it after the `;` so we don't
              # produce `iA16a;**` (functional but ugly) — `; **` is
              # the canonical neighbor shape.
              "; #{line[(col + 1)..]}"
            else
              # No space at all (rare). Inject `; `.
              "; #{line[col..]}"
            end
          source_lines[line_idx] = "#{line[0...col]}#{replacement}"
        end

        source_lines.join("\n")
      end
    end
  end
end
