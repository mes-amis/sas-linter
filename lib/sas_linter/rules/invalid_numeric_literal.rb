# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag tokens the lexer typed as INTEGER_LITERAL whose text isn't
    # actually a valid SAS numeric literal — typically a digit-prefixed
    # identifier the lexer munched into one token, e.g.
    #
    #     if K9d = 1f then do;     * `1f` is not valid SAS
    #     x = 1d2;                  * `D` exponent is Fortran, not SAS
    #
    # Real SAS only accepts two integer-shaped literals:
    #
    #   * plain decimal:  `[0-9]+`
    #   * hex literal:    `[0-9][0-9A-Fa-f]*[xX]` (trailing `x`/`X`)
    #
    # Float and exponent forms (`1.0`, `1e3`) get their own token types
    # (FLOAT_LITERAL / FLOAT_EXPONENT_LITERAL) and aren't checked here.
    class InvalidNumericLiteral < Rule
      rule_id :invalid_numeric_literal
      description "INTEGER_LITERAL must be a plain decimal or a SAS hex " \
                  "literal (`0FFx`-style); reject suffixes like `1f` or " \
                  "`1d2` that the lexer accepts but SAS does not."
      severity :warning

      TT = SasLexer::Lexer::TokenType

      VALID = /\A(?:[0-9]+|[0-9][0-9A-Fa-f]*[xX])\z/

      MESSAGE_SUFFIX = "is not a valid SAS numeric literal — SAS has no " \
                       "`f`/`F`/`L` numeric suffixes and uses `E` (not `D`) " \
                       "for exponents; hex literals must end in `x`/`X`."

      def check(tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        tokens.filter_map do |t|
          next unless t[:type] == TT::INTEGER_LITERAL && !VALID.match?(t[:text])

          finding(
            line: t[:start_line], column: t[:start_column] + 1,
            message: "`#{t[:text]}` #{MESSAGE_SUFFIX}", path: path
          )
        end
      end
    end
  end
end
