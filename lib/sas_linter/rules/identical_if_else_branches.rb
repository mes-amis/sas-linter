# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag `if COND then S; else S;` where the THEN and ELSE bodies are
    # identical token-for-token — the condition has no effect on the
    # outcome, which is almost always a copy-paste error.
    #
    # Motivating bug (`docs/AK_LOC_HOME_CARE_SCALE_notes.txt` #1):
    #
    #     if iK3 in (6,7,8) then NF1_2=0; else NF1_2=0;
    #
    # Both branches assign `NF1_2 = 0`; the THEN should have been `=1`.
    #
    # Scope: simple-statement bodies only (`then STMT; else STMT;`). The
    # block form (`then do; ... end; else do; ... end;`) is ignored — it's
    # rare and the equivalence check would need to span an unbounded body.
    class IdenticalIfElseBranches < Rule
      rule_id :identical_if_else_branches
      description "`if ... then S; else S;` — THEN and ELSE bodies are " \
                  "identical, so the condition has no effect."
      severity :warning

      TT = SasLexer::Lexer::TokenType

      def check(tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        findings = []
        i = 0

        while i < tokens.length
          tok = tokens[i]

          if tok[:type] == TT::KW_THEN
            # Bail on `then do;` — only handle simple statement bodies.
            nxt = tokens[i + 1]
            if nxt && nxt[:type] != TT::KW_DO
              then_body, after_then = collect_simple_body(tokens, i + 1)
              if then_body && tokens[after_then] && tokens[after_then][:type] == TT::KW_ELSE
                else_idx = after_then
                # Same bail-out for `else do;`.
                else_first = tokens[else_idx + 1]
                if else_first && else_first[:type] != TT::KW_DO
                  else_body, after_else = collect_simple_body(tokens, else_idx + 1)
                  if else_body && bodies_equivalent?(then_body, else_body)
                    findings << finding(
                      line: tokens[else_idx][:start_line],
                      column: tokens[else_idx][:start_column] + 1,
                      message: "`if ... then #{render_body(then_body)}; else #{render_body(else_body)};` — " \
                               "branches are identical; the condition has no effect.",
                      path: path
                    )
                    i = after_else
                    next
                  end
                end
              end
            end
          end

          i += 1
        end

        findings
      end

      private

      # Collect tokens for one statement body starting at `start_idx`, up to
      # (but not including) the terminating SEMI. Returns [body_tokens,
      # index_after_semi] or [nil, start_idx] if no SEMI is found before EOF.
      def collect_simple_body(tokens, start_idx)
        body = []
        k = start_idx
        while k < tokens.length
          t = tokens[k]
          return [body, k + 1] if t[:type] == TT::SEMI

          body << t
          k += 1
        end
        [nil, start_idx]
      end

      # Two bodies are equivalent if they have the same token types and the
      # same normalized text. Identifiers and keywords are SAS-case-insensitive,
      # so compare downcased text.
      def bodies_equivalent?(a, b)
        return false unless a.length == b.length

        a.each_with_index.all? do |ta, idx|
          tb = b[idx]
          ta[:type] == tb[:type] && ta[:text].downcase == tb[:text].downcase
        end
      end

      def render_body(body)
        body.map { |t| t[:text] }.join(" ").gsub(/\s+([,;()])/, '\1').gsub(/([,(])\s+/, '\1')
      end
    end
  end
end
