# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag SAS sources that ship with the "CHOOSE ONE OF THE BELOW STATEMENTS"
    # banner. The banner introduces a block of mutually-exclusive validity
    # guards (typically `[USE FOR HC OR CHA WITH FS]`, `[USE FOR LTCF]`,
    # `[USE FOR CHA WITHOUT FS]`, etc.), all commented out, and asks the
    # downstream consumer to pick one before the source will work.
    #
    # Why it's an antipattern:
    #   - The source is broken-by-default — every consumer must mutate it
    #     before use.
    #   - SAS won't error on the dangling `end;` of the (also-commented)
    #     block, but the algorithm runs unguarded if no variant is picked.
    #   - The deployment-context decision should belong to a config file or
    #     a separate per-context source variant, not to a comment-toggle
    #     buried in the middle of the algorithm.
    #
    # Companion rule: `commented_out_guard` flags the individual disabled
    # guards. This rule flags the banner that introduces them, so we can
    # find every file that ships in the multi-template state regardless
    # of whether any variant has already been activated.
    class ChooseOneTemplate < Rule
      rule_id :choose_one_template
      description "Source ships with a 'CHOOSE ONE OF THE BELOW STATEMENTS' " \
                  "banner — broken-by-default; consumers must mutate the " \
                  "source to pick a deployment-context guard."
      severity :warning

      TT = SasLexer::Lexer::TokenType
      TC = SasLexer::Lexer::TokenChannel

      BANNER = /CHOOSE\s+ONE\s+OF\s+THE\s+BELOW\s+STATEMENTS/i

      def check(_tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless all_tokens

        all_tokens.filter_map do |tok|
          next unless tok[:channel] == TC::COMMENT
          next unless tok[:type] == TT::COMMENT_STAT
          next unless tok[:text] =~ BANNER

          finding(
            line: tok[:start_line],
            column: tok[:start_column] + 1,
            message: "'CHOOSE ONE OF THE BELOW STATEMENTS' banner — source is " \
                     "broken-by-default; the alternative validity guards below " \
                     "are all commented out so every consumer must edit this " \
                     "file. Pick one variant, delete the others, and remove " \
                     "this banner.",
            path: path
          )
        end
      end
    end
  end
end
