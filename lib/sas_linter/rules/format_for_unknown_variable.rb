# frozen_string_literal: true

require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Flag `format` / `informat` / `attrib ... format=` statements that
    # name a variable referenced nowhere else in the file. Almost always
    # a typo (`attrib totalscore format=flagx.;` when every other use is
    # `total_score`). SAS itself silently binds the format to a phantom
    # column and runs; downstream tooling that resolves variable
    # references (e.g. sas-ruby) refuses to compile such a file.
    #
    # The rule is conservative: a file that pulls variables in from an
    # external source — `set`, `merge`, `update`, `infile`, `input` — is
    # skipped entirely, since a format target may legitimately name a
    # column the linter can't see.
    class FormatForUnknownVariable < Rule
      rule_id :format_for_unknown_variable
      description "Variable named in a `format` / `informat` / `attrib` " \
                  "statement is referenced nowhere else in the file — " \
                  "almost always a typo."
      severity :warning

      TT = SasLexer::Lexer::TokenType

      FORMAT_KIND_BY_TYPE = {
        TT::KW_FORMAT => :format,
        TT::KW_INFORMAT => :informat,
        TT::KW_ATTRIB => :attrib
      }.freeze

      EXTERNAL_INPUT_TYPES = [
        TT::KW_SET, TT::KW_MERGE, TT::KW_UPDATE, TT::KW_INFILE, TT::KW_INPUT
      ].freeze

      # Statements that name variables for declaration only — the names
      # they reference don't count as "real uses" because if a variable
      # only appears in declaration statements it's still dead code.
      # Keyword-typed openers:
      DECLARATION_TYPES = [
        TT::KW_FORMAT, TT::KW_INFORMAT, TT::KW_ATTRIB,
        TT::KW_LABEL, TT::KW_LENGTH, TT::KW_KEEP, TT::KW_DROP, TT::KW_ARRAY
      ].freeze

      # IDENTIFIER-typed openers (the lexer doesn't keyword these):
      #   `retain` is a data-step declaration;
      #   `value` / `invalue` / `picture` introduce a `proc format` body.
      DECLARATION_TEXT = %w[retain value invalue picture].freeze

      def check(tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        external_input = false
        targets = []
        use_names = Set.new

        each_statement(tokens) do |stmt|
          opener = stmt[0]

          if EXTERNAL_INPUT_TYPES.include?(opener[:type])
            external_input = true
            next
          end

          kind = FORMAT_KIND_BY_TYPE[opener[:type]]
          if kind
            collect_targets(stmt, kind, targets)
            next
          end

          next if declaration_statement?(opener)

          collect_uses(stmt, use_names)
        end

        return [] if external_input

        targets.filter_map do |t, kind|
          next if use_names.include?(t[:text].downcase)

          finding(
            line: t[:start_line],
            column: t[:start_column] + 1,
            message: "`#{kind}` assigns a format to `#{t[:text]}` but " \
                     "that variable is not referenced anywhere else in " \
                     "this file — likely a typo.",
            path: path
          )
        end
      end

      private

      # Yield each `; ... ;` slice (opener at index 0, no trailing `;`).
      # Stray semicolons produce empty slices and are skipped.
      def each_statement(tokens)
        start = 0
        tokens.each_with_index do |t, i|
          next unless t[:type] == TT::SEMI

          slice = tokens[start...i]
          yield slice unless slice.empty?
          start = i + 1
        end
      end

      def declaration_statement?(opener)
        return true if DECLARATION_TYPES.include?(opener[:type])
        return true if opener[:type] == TT::IDENTIFIER &&
                       DECLARATION_TEXT.include?(opener[:text].downcase)

        false
      end

      def collect_targets(stmt, kind, targets)
        stmt.each_with_index do |t, i|
          next unless t[:type] == TT::IDENTIFIER
          next unless variable_target?(stmt, i)

          targets << [t, kind]
        end
      end

      # In `format`/`informat`, the format name is the identifier
      # byte-adjacent to a following `.` (`date9.`, `flagx.`). In
      # `attrib`, the format name additionally follows `=`
      # (`format=flagx.`). Everything else is a variable target.
      def variable_target?(stmt, i)
        t = stmt[i]
        nxt = stmt[i + 1]
        prev = i.positive? ? stmt[i - 1] : nil

        return false if nxt && nxt[:type] == TT::DOT && nxt[:start] == t[:end]
        return false if prev && prev[:type] == TT::ASSIGN

        true
      end

      def collect_uses(stmt, names)
        stmt.each_with_index do |t, i|
          next unless t[:type] == TT::IDENTIFIER
          next unless variable_use?(stmt, i)

          names << t[:text].downcase
        end
      end

      # Same exclusions as `inconsistent_variable_case`: byte-adjacent
      # `<name>.` (format reference) and `<lib>.<member>` second halves
      # don't name a variable in the current step.
      def variable_use?(stmt, i)
        t = stmt[i]
        nxt = stmt[i + 1]
        prev = i.positive? ? stmt[i - 1] : nil

        return false if nxt && nxt[:type] == TT::DOT && nxt[:start] == t[:end]
        return false if prev && prev[:type] == TT::DOT && prev[:end] == t[:start]

        true
      end
    end
  end
end
