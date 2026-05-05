# frozen_string_literal: true

require_relative "../../sas_linter"

class SasLinter
  module Rules
    # Flag non-standard line endings in SAS sources. Two patterns
    # appear in legacy SAS sources and tend to be hand-fixed when
    # they show up:
    #
    #   1. `\r\r\n` — double CR before LF. Word/Outlook copy-paste
    #      injects an extra CR; SAS Viya tolerates it but downstream
    #      tools and diffs treat the file as if every line had a
    #      trailing literal CR character.
    #
    #   2. Lone `\r` (CR not followed by LF) — old-Mac CR-only
    #      endings. SAS Viya treats the entire file as one logical
    #      line, breaking saspy's shard-based submission flow.
    #
    # Autofix collapses `\r\r\n` to `\r\n` unconditionally and maps
    # every lone `\r` to the file's dominant ending: `\r\n` if the
    # source has any CRLF (i.e. it's a Windows file with stragglers),
    # `\n` otherwise (i.e. pure-CR file → POSIX).
    #
    # Recognized config options:
    #   autofix: true | false   (default: false)
    class LineEndings < Rule
      rule_id :line_endings
      description "Source has non-standard line endings (double-CR or lone CR)."
      severity :warning

      def self.supports_autofix?
        true
      end

      def check(_tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless source

        findings = []
        bytes = source.b.bytes
        line = 1
        col = 1
        i = 0
        n = bytes.length

        while i < n
          b = bytes[i]
          if b == 0x0D && bytes[i + 1] == 0x0D && bytes[i + 2] == 0x0A
            findings << finding(
              line: line,
              column: col,
              message: "double CR before LF (\\r\\r\\n)#{autofix? ? ' (autofixed)' : ''}",
              path: path
            )
            line += 1
            col = 1
            i += 3
          elsif b == 0x0D && bytes[i + 1] == 0x0A
            line += 1
            col = 1
            i += 2
          elsif b == 0x0D
            findings << finding(
              line: line,
              column: col,
              message: "lone CR (\\r)#{autofix? ? ' (autofixed)' : ''}",
              path: path
            )
            line += 1
            col = 1
            i += 1
          elsif b == 0x0A
            line += 1
            col = 1
            i += 1
          else
            col += 1
            i += 1
          end
        end
        findings
      end

      # Collapse `\r\r\n` to `\r\n`; map every remaining lone `\r` to
      # the file's dominant terminator (`\r\n` if any CRLF survives,
      # else `\n`).
      def autofix(source)
        # Step 1: remove the duplicate CR in `\r\r\n` sequences. This
        # leaves at most one `\r` adjacent to `\n` (real CRLF) and
        # any other `\r` on its own.
        step1 = source.b.gsub(/\r\r\n/, "\r\n")

        # Step 2: pick the dominant terminator. `\r\n` wins if there
        # are any CRLF sequences; otherwise we collapse to LF.
        dominant_crlf = step1.include?("\r\n")
        replacement = dominant_crlf ? "\r\n" : "\n"

        # Step 3: replace every lone `\r` (not followed by `\n`) with
        # the dominant ending. The negative lookahead leaves real
        # CRLF intact when CRLF is the dominant style.
        step1.gsub(/\r(?!\n)/, replacement).force_encoding(source.encoding)
      end
    end
  end
end
