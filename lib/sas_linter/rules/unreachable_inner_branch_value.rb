# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag inner branches whose comparison values are excluded by an
    # enclosing `if VAR in (...) then do; ... end;` guard.
    #
    # Motivating shape: an outer guard
    # `if RANK in (0,1,2,3,4,5,6,8) then do;` omits 7, while an inner
    # `if RANK in (5,6,7,8) then cOut = 2;` lists 7. Value 7 falls
    # through the outer guard, so the inner branch can never fire for it
    # and cOut silently stays missing.
    #
    # Detection: outer guard pushes a {var, allowed_set} frame; inner
    # `if VAR in (...)`, `if VAR = N`, or `if VAR eq N` references inside
    # the same DO block are checked against that set. Values absent from
    # the outer set produce a finding.
    class UnreachableInnerBranchValue < Rule
      rule_id :unreachable_inner_branch_value
      description "Inner branch references a value that the enclosing " \
                  "outer guard excludes — branch is unreachable for that value."
      severity :warning

      TT = SasLexer::Lexer::TokenType

      # Outer guard pattern: KW_IF IDENT KW_IN LPAREN <lits...> RPAREN KW_THEN KW_DO SEMI
      # Inner check patterns:
      #   KW_IF IDENT(V) KW_IN LPAREN <lits...> RPAREN
      #   KW_IF IDENT(V) KW_EQ <lit>
      #   KW_IF IDENT(V) ASSIGN <lit>     (SAS uses `=` as comparison in IF)

      def check(tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        findings = []
        guard_stack = [] # array of {var:, allowed:, depth:}
        do_depth = 0
        i = 0

        while i < tokens.length
          tok = tokens[i]

          if tok[:type] == TT::KW_IF
            consumed, frame, inner_findings =
              analyze_if(tokens, i, do_depth, guard_stack, path)
            findings.concat(inner_findings)
            if frame
              guard_stack.push(frame)
              do_depth += 1
            end
            i += consumed
            next
          end

          if tok[:type] == TT::KW_DO
            # bare `do;` (no IF prefix), or `do i = 1 to N;` — both increment depth
            do_depth += 1
            i += 1
            next
          end

          if tok[:type] == TT::KW_END
            do_depth -= 1 if do_depth > 0
            guard_stack.pop while guard_stack.last && guard_stack.last[:depth] > do_depth
            i += 1
            next
          end

          i += 1
        end

        findings
      end

      private

      # Returns [tokens_consumed, new_guard_frame_or_nil, findings].
      # Skips ahead through the entire condition expression but not the body.
      def analyze_if(tokens, i, do_depth, guard_stack, path)
        # tokens[i] is KW_IF
        j = i + 1
        ident = tokens[j]
        return [1, nil, []] unless ident && ident[:type] == TT::IDENTIFIER

        var = ident[:text].downcase
        op = tokens[j + 1]
        return [1, nil, []] unless op

        values, end_of_cond, simple = parse_comparison(tokens, j + 1, var, ident[:text])
        return [1, nil, []] unless simple

        # Now look for `then do;` immediately after end_of_cond to detect outer guards
        k = end_of_cond
        is_outer_guard =
          tokens[k] && tokens[k][:type] == TT::KW_THEN &&
          tokens[k + 1] && tokens[k + 1][:type] == TT::KW_DO &&
          tokens[k + 2] && tokens[k + 2][:type] == TT::SEMI

        # Generate findings for any active guard on this variable. (Skip the
        # outer guard itself — its own values define the allowed set.)
        findings = []
        unless is_outer_guard
          active = guard_stack.reverse.find { |f| f[:var] == var }
          if active
            values.each do |val|
              next if active[:allowed].include?(val[:key])

              findings << finding(
                line: val[:line],
                column: val[:column],
                message: "value #{val[:display]} for #{ident[:text]} is excluded by " \
                         "the enclosing `if #{ident[:text]} in (...)` guard at line #{active[:line]}; " \
                         "this branch is unreachable.",
                path: path
              )
            end
          end
        end

        new_frame = nil
        consumed = (end_of_cond - i)

        if is_outer_guard
          new_frame = {
            var: var,
            allowed: values.map { |v| v[:key] }.to_set,
            depth: do_depth + 1,
            line: tokens[i][:start_line]
          }
          consumed = (k + 3) - i # consume through SEMI
        end

        [consumed, new_frame, findings]
      end

      # Parse one of:
      #   KW_IN  LPAREN <lits...> RPAREN
      #   KW_EQ  <lit>
      #   ASSIGN <lit>
      # Returns [values, index_after_condition, simple?].
      # `values` is array of {key:, display:, line:, column:}.
      # `simple?` is false if the condition contains anything we can't reason
      # about (macros, references, expressions) — caller bails.
      def parse_comparison(tokens, op_idx, _var, _orig_text)
        op = tokens[op_idx]
        return [[], op_idx, false] unless op

        case op[:type]
        when TT::KW_IN
          lparen = tokens[op_idx + 1]
          return [[], op_idx, false] unless lparen && lparen[:type] == TT::LPAREN

          values = []
          k = op_idx + 2
          loop do
            t = tokens[k]
            return [[], op_idx, false] unless t

            if t[:type] == TT::RPAREN
              return [values, k + 1, true]
            elsif t[:type] == TT::COMMA
              k += 1
              next
            elsif (val = literal_value(t))
              values << val
              k += 1
            else
              # Unparseable literal (macro, identifier, expression). Bail.
              return [[], op_idx, false]
            end
          end
        when TT::KW_EQ, TT::ASSIGN
          lit = tokens[op_idx + 1]
          val = literal_value(lit)
          return [[], op_idx, false] unless val

          [[val], op_idx + 2, true]
        else
          [[], op_idx, false]
        end
      end

      def literal_value(tok)
        return nil unless tok

        case tok[:type]
        when TT::INTEGER_LITERAL
          n = Integer(tok[:text]) rescue (return nil)
          { key: ["int", n], display: tok[:text], line: tok[:start_line], column: tok[:start_column] + 1 }
        when TT::FLOAT_LITERAL
          f = Float(tok[:text]) rescue (return nil)
          # Treat 5.0 as equivalent to 5 for set membership.
          key = (f == f.to_i) ? ["int", f.to_i] : ["float", f]
          { key: key, display: tok[:text], line: tok[:start_line], column: tok[:start_column] + 1 }
        when TT::STRING_LITERAL
          { key: ["str", tok[:text]], display: tok[:text], line: tok[:start_line], column: tok[:start_column] + 1 }
        end
      end
    end
  end
end
