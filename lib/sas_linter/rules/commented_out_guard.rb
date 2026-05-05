# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag SAS line-comments (`* ... ;`) whose body looks like a disabled
    # validity guard — specifically, the body contains both an `IF` and a
    # `THEN DO` (case-insensitive).
    #
    # Motivating shape: a source's outer `if ... then do;` validity guard
    # is commented out by a leading `*`, leaving an orphan `end;` further
    # down. The body then runs unguarded for inputs the guard would have
    # rejected. Worth a human review on each finding — either the guard
    # should be live, or the orphan `end;` should be removed.
    class CommentedOutGuard < Rule
      rule_id :commented_out_guard
      description "SAS `* ... ;` line comment looks like a disabled `if " \
                  "... then do` validity guard — review and either restore " \
                  "the guard or remove the orphan `end;`."
      severity :warning

      TT = SasLexer::Lexer::TokenType
      TC = SasLexer::Lexer::TokenChannel

      # Match `if ... then do` anywhere in the comment body, case-insensitive.
      # Look for `then` followed (after whitespace and possibly more tokens)
      # by `do` — the SAS authoring style where the guard expression is
      # spread across multiple lines.
      GUARD_PATTERN = /\bif\b.*\bthen\b\s+do\b/im

      def check(_tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless all_tokens

        all_tokens.filter_map do |tok|
          next unless tok[:channel] == TC::COMMENT
          next unless tok[:type] == TT::COMMENT_STAT

          body = tok[:text]
          # Only flag SAS statement-comments that start with `*` (not `**`),
          # since `** ... **;` is a header comment style and `* ...;` is
          # the disable-this-statement style.
          next unless body =~ /\A\s*\*(?!\*)/
          next unless body =~ GUARD_PATTERN

          finding(
            line: tok[:start_line],
            column: tok[:start_column] + 1,
            message: "looks like a disabled validity guard (`* if ... then do; ...`); " \
                     "review whether the guard should be live or whether the matching " \
                     "`end;` is now orphaned.",
            path: path
          )
        end
      end
    end
  end
end
