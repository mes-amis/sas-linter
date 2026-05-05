# frozen_string_literal: true

require_relative "../../sas_linter"

class SasLinter
  module Rules
    # Flag end-of-line trailing whitespace (spaces or tabs that
    # appear before the line terminator). Trailing whitespace is
    # invisible noise — it inflates diffs, fights with editor
    # auto-trim, and hides intent. Supports `autofix` to strip the
    # offending bytes in place.
    #
    # Recognized config options:
    #   autofix: true | false   (default: false)
    class TrailingWhitespace < Rule
      rule_id :trailing_whitespace
      description "Line has trailing whitespace before the newline."
      severity :warning

      TRAILING_WS = /([ \t]+)(\r?\n|\z)/

      def self.supports_autofix?
        true
      end

      def check(_tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless source

        findings = []
        source.each_line.with_index do |line, idx|
          chomped = line.sub(/\r?\n\z/, "")
          next unless chomped =~ /([ \t]+)\z/

          ws_start = ::Regexp.last_match.begin(1)
          findings << finding(
            line: idx + 1,
            column: ws_start + 1,
            message: "trailing whitespace#{autofix? ? ' (autofixed)' : ''}",
            path: path
          )
        end
        findings
      end

      # Strip end-of-line trailing whitespace while preserving the
      # original line terminator (LF or CRLF) and the trailing
      # newline (or its absence) on the final line.
      def autofix(source)
        source.gsub(TRAILING_WS) { ::Regexp.last_match(2) }
      end
    end
  end
end
