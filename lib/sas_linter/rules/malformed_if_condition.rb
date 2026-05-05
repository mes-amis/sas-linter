# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Validate that `if ... then` conditions form well-shaped boolean
    # expressions. Catches authoring mistakes the lexer cheerfully
    # accepts but that won't run, e.g.
    #
    #     if A1 = 1 A2 = 2 then ...    * missing `and`/`or`
    #     if A1 = 1 and then ...       * trailing operator
    #     if = 1 then ...               * leading operator, no left operand
    #     if then ...                   * empty condition
    #     A1 = 1 then ...              * missing `if`
    #     if (a = 1 and b = 2 then ...  * unbalanced parens
    #
    # Strategy: at each `KW_IF`, walk forward to the matching top-level
    # `KW_THEN` (or `;` for a subsetting `if`) running a tiny
    # operand/operator state machine. Top-level only — anything inside
    # parens is treated as a single sub-expression so function calls
    # and `in (...)` lists don't trigger false positives.
    #
    # An orphan `KW_THEN` (one not consumed by an enclosing `if`) is
    # reported as a likely missing `if`.
    class MalformedIfCondition < Rule
      rule_id :malformed_if_condition
      description "Validate `if ... then` conditions form a well-shaped " \
                  "boolean expression (no missing operators, operands, " \
                  "or `if` keyword; balanced parens)."
      severity :warning

      TT = SasLexer::Lexer::TokenType

      COMPARISON_OPS = [
        TT::ASSIGN, TT::KW_EQ, TT::KW_NE, TT::NE, TT::KW_LT, TT::LT, TT::KW_LE, TT::LE,
        TT::KW_GT, TT::GT, TT::KW_GE, TT::GE, TT::KW_IN, TT::SOUNDS_LIKE, TT::GTLT, TT::LTGT,
        TT::KW_EQT, TT::KW_GTT, TT::KW_LTT, TT::KW_GET, TT::KW_LET, TT::KW_NET
      ].freeze

      LOGICAL_OPS = [TT::KW_AND, TT::KW_OR, TT::AMP, TT::PIPE, TT::PIPE2].freeze

      ARITHMETIC_OPS = [TT::PLUS, TT::MINUS, TT::STAR, TT::FSLASH, TT::STAR2,
                        TT::EXCL, TT::EXCL2, TT::BPIPE, TT::BPIPE2].freeze

      BINOPS = (COMPARISON_OPS + LOGICAL_OPS + ARITHMETIC_OPS).to_set.freeze

      # `+`/`-` are also binary; the state machine disambiguates by
      # checking whether we currently expect an operand.
      UNARY_PREFIXES = [TT::KW_NOT, TT::NOT, TT::MINUS, TT::PLUS].to_set.freeze

      OPERAND_TOKENS = [
        TT::IDENTIFIER,
        TT::INTEGER_LITERAL, TT::FLOAT_LITERAL, TT::FLOAT_EXPONENT_LITERAL,
        TT::STRING_LITERAL, TT::HEX_STRING_LITERAL, TT::BIT_TESTING_LITERAL,
        TT::DATE_LITERAL, TT::DATE_TIME_LITERAL, TT::TIME_LITERAL, TT::NAME_LITERAL,
        TT::MACRO_VAR_RESOLVE, TT::MACRO_IDENTIFIER, TT::MACRO_STRING,
        TT::STRING_EXPR_START
      ].to_set.freeze

      def check(tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        findings = []
        consumed_thens = {}
        i = 0

        while i < tokens.length
          tok = tokens[i]

          if tok[:type] == TT::KW_IF
            new_i, sub_findings = analyze_if(tokens, i, path, consumed_thens)
            findings.concat(sub_findings)
            i = new_i
            next
          end

          if tok[:type] == TT::KW_THEN && !consumed_thens[i]
            findings << finding(
              line: tok[:start_line],
              column: tok[:start_column] + 1,
              message: "`then` without a preceding `if` condition — likely missing `if`.",
              path: path
            )
          end

          i += 1
        end

        findings
      end

      private

      # Walk from `if` at `tokens[start]` until the matching `then`
      # (or `;` for a subsetting `if`), validating expression shape.
      # Returns [next_i, findings].
      #
      # Emits at most ONE finding per `if`: one structural defect (e.g.
      # `iK2g in 0,1)` — missing `(` after `in`) cascades through the
      # state machine into adjacent unbalanced-paren / orphan-then
      # errors. After the first finding, we set `broken` and walk
      # forward to the next top-level `;`, marking any `KW_THEN`
      # tokens as consumed so the outer loop's orphan-then detector
      # doesn't double-fire on this same broken statement.
      # Mutates `consumed_thens`.
      def analyze_if(tokens, start, path, consumed_thens)
        findings = []
        state = :expect_operand
        paren_depth = 0
        open_parens = []
        cond_started = false
        last_op_tok = nil
        broken = false

        add_finding = lambda do |tok, message|
          findings << finding(
            line: tok[:start_line], column: tok[:start_column] + 1,
            message: message, path: path
          )
          broken = true
        end

        i = start + 1
        while i < tokens.length
          t = tokens[i]
          type = t[:type]

          # Recovery mode: skip ahead to the next `;`, marking any
          # `then`s we pass over as consumed so they don't flag as
          # orphan in the outer loop. Paren state is intentionally
          # ignored — once we've emitted a finding we don't trust
          # the depth counter to be meaningful.
          if broken
            consumed_thens[i] = true if type == TT::KW_THEN
            return [i + 1, findings] if type == TT::SEMI

            i += 1
            next
          end

          if type == TT::KW_THEN && paren_depth.zero?
            flag_terminal(findings, path, state, cond_started, last_op_tok, t, "then")
            consumed_thens[i] = true
            return [i + 1, findings]
          end

          if type == TT::SEMI && paren_depth.zero?
            flag_terminal(findings, path, state, cond_started, last_op_tok, t, "subsetting `if`")
            return [i + 1, findings]
          end

          # `then` / `;` inside open parens means a paren never closed.
          # Flag at the offending `(` and drop into recovery mode.
          if (type == TT::KW_THEN || type == TT::SEMI) && paren_depth.positive?
            lp = open_parens.first
            add_finding.call(lp, "unbalanced `(` in `if` condition (no matching `)` " \
                                 "before `#{t[:text]}`).")
            consumed_thens[i] = true if type == TT::KW_THEN
            i += 1
            next
          end

          if type == TT::LPAREN || type == TT::LBRACK
            cond_started = true
            paren_depth += 1
            open_parens.push(t)
            i += 1
            next
          end

          if type == TT::RPAREN || type == TT::RBRACK
            if paren_depth.zero?
              add_finding.call(t, "unbalanced `#{t[:text]}` in `if` condition.")
              i += 1
              next
            end
            paren_depth -= 1
            open_parens.pop
            # A parenthesized sub-expression, function-call arg list,
            # or array subscript that just closed counts as one
            # completed operand.
            state = :expect_operator if paren_depth.zero?
            i += 1
            next
          end

          # Inside parens we don't validate — the whole `(...)` is one
          # atom at the top level.
          if paren_depth.positive?
            i += 1
            next
          end

          # `,` at top level only appears inside `in (...)`, which is
          # paren-wrapped. Treat as a no-op if it leaks through.
          if type == TT::COMMA
            i += 1
            next
          end

          cond_started = true

          if state == :expect_operand
            if UNARY_PREFIXES.include?(type)
              i += 1
              next
            end

            if OPERAND_TOKENS.include?(type)
              state = :expect_operator
              i += 1
              next
            end

            if BINOPS.include?(type)
              msg = if last_op_tok.nil?
                      "operator `#{t[:text]}` at start of `if` condition with no left operand."
                    else
                      "operator `#{t[:text]}` follows operator `#{last_op_tok[:text]}` " \
                        "with no operand between them."
                    end
              add_finding.call(t, msg)
              last_op_tok = t
              i += 1
              next
            end

            # Unknown token in operand position — treat opaquely as
            # one operand to keep walking. Reduces false positives on
            # SAS shapes we don't fully model (e.g. DOT for missing
            # values, format references).
            state = :expect_operator
            i += 1
            next
          end

          # state == :expect_operator
          if BINOPS.include?(type)
            last_op_tok = t
            state = :expect_operand
            i += 1
            next
          end

          # Negated comparisons: `not eq`, `not in`, `not lt`, `^=`,
          # `^in`, `^<`, etc. The lexer splits these into a NOT/`^`
          # token and a comparison op; recognize the pair as one
          # binary operator so the state machine doesn't see two
          # operators in a row.
          if (type == TT::KW_NOT || type == TT::NOT) && (nxt = tokens[i + 1]) &&
             COMPARISON_OPS.include?(nxt[:type])
            last_op_tok = nxt
            state = :expect_operand
            i += 2
            next
          end

          if OPERAND_TOKENS.include?(type) || UNARY_PREFIXES.include?(type)
            add_finding.call(t,
                             "missing operator before `#{t[:text]}` in `if` condition — " \
                             "perhaps a missing `and`/`or`?")
            i += 1
            next
          end

          i += 1
        end

        # Reached EOF without seeing `then` or `;`.
        [i, findings]
      end

      def flag_terminal(findings, path, state, cond_started, last_op_tok, terminator, where)
        if !cond_started
          findings << finding(
            line: terminator[:start_line], column: terminator[:start_column] + 1,
            message: "`if #{where}` with empty condition.",
            path: path
          )
        elsif state == :expect_operand && last_op_tok
          findings << finding(
            line: last_op_tok[:start_line], column: last_op_tok[:start_column] + 1,
            message: "operator `#{last_op_tok[:text]}` has no right operand before " \
                     "`#{terminator[:text]}`.",
            path: path
          )
        end
      end
    end
  end
end
