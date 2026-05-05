# frozen_string_literal: true

require_relative "../../sas_linter"

class SasLinter
  module Rules
    # Flag literal TAB (`\t`) characters in source. SAS authoring
    # conventions strongly prefer spaces — tabs render at different
    # widths in different editors and break the column alignment
    # SAS sources often rely on for readability.
    #
    # When `autofix` is true, each tab is replaced with the number
    # of spaces needed to reach the next column-aligned tab stop
    # (i.e., the standard `expand(1)` semantics with the configured
    # width). A tab in column N expands to `width - (N % width)`
    # spaces, so leading whitespace, mid-line alignment, and pre-
    # token padding all stay column-aligned post-fix.
    #
    # Recognized config options:
    #   width:   integer (default 8)
    #   autofix: true | false (default false)
    class TabExpansion < Rule
      rule_id :tab_expansion
      description "Line contains a literal TAB character; will be expanded to spaces."
      severity :warning

      DEFAULT_WIDTH = 8

      def self.supports_autofix?
        true
      end

      def self.from_config(opts = {})
        opts = opts.transform_keys(&:to_s)
        new(
          width: Integer(opts.fetch("width", DEFAULT_WIDTH)),
          autofix: opts["autofix"] ? true : false
        )
      end

      attr_reader :width

      def initialize(width: DEFAULT_WIDTH, autofix: false)
        super(autofix: autofix)
        raise ArgumentError, "width must be positive (got #{width})" if width.to_i < 1

        @width = Integer(width)
      end

      def check(_tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless source

        findings = []
        source.each_line.with_index do |line, idx|
          chomped = line.sub(/\r?\n\z/, "")
          next unless chomped.include?("\t")

          chomped.each_char.with_index do |ch, col|
            next unless ch == "\t"

            findings << finding(
              line: idx + 1,
              column: col + 1,
              message: "tab character#{autofix? ? " (expanded to #{@width}-space tab stop)" : ''}",
              path: path
            )
          end
        end
        findings
      end

      # Replace every tab with `width - (col % width)` spaces, where
      # `col` is the post-expansion column of the tab. Re-counts per
      # line so the line terminator resets the column.
      def autofix(source)
        source.each_line.map { |line| expand_line(line) }.join
      end

      private

      def expand_line(line)
        eol_match = line.match(/\r?\n\z/)
        terminator = eol_match ? eol_match[0] : ""
        body = eol_match ? line[0...eol_match.begin(0)] : line

        out = +""
        body.each_char do |ch|
          if ch == "\t"
            out << (" " * (@width - (out.length % @width)))
          else
            out << ch
          end
        end
        out + terminator
      end
    end
  end
end
