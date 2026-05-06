# frozen_string_literal: true

require_relative "../../sas_linter"

class SasLinter
  module Rules
    # Flag and (optionally) rewrite encoding issues in SAS source —
    # smart quotes (`‘ ’ “ ”`), en/em dashes (`– —`), ellipsis (`…`),
    # non-break space, U+2000–U+200A typographic spaces, line/para
    # separators, and the Windows-1252 single-byte forms of the same
    # characters (0x91/0x92, 0x93/0x94, 0x96/0x97, 0xA0, …) that
    # bypass UTF-8 transcoding when source files arrive from Word /
    # Outlook / a legacy Latin-1 round-trip.
    #
    # The rule has two layers, both off by default:
    #
    #   1. `use_defaults: true` enables the canonical fix
    #      table — UTF8_REPLACEMENTS (multibyte UTF-8 smart
    #      punctuation) plus BYTE_REPLACEMENTS (single Windows-1252
    #      bytes the lexer can't make sense of). The fixer walks the
    #      source as a byte stream and only touches a Win-1252 byte
    #      when it's not already part of a valid UTF-8 sequence — so
    #      names like `MÖLLER` (`\xC3\x96`) survive intact.
    #
    #   2. `replacements: { from => to }` adds project-specific
    #      string-level substitutions. Use this for site-local
    #      cleanups, stylistic preferences (em-dash → "--" instead
    #      of "-"), to override default behavior on specific bytes,
    #      or to add extra characters not in the default table.
    #
    # Findings carry a line:column position for every match. Autofix
    # runs the user `replacements:` map FIRST and the canonical
    # fixer SECOND — so a project-specific pattern can target byte
    # sequences the canonical defaults would otherwise consume
    # (e.g. catch a multi-byte ellipsis in a specific surname before
    # the default `… → ...` rewrite hits it).
    #
    # Recognized config options:
    #   use_defaults: true | false                          (default: false)
    #   replacements: { String => String }                  (default: {})
    #   autofix:      true | false                          (default: false)
    class EncodingIssues < Rule
      rule_id :encoding_issues
      description "Source contains smart-punctuation / Win-1252 byte sequences."
      severity :warning

      # Map of UTF-8 (multi-byte) byte sequences to their ASCII
      # replacement. Stored as raw byte strings so substitution
      # doesn't depend on the encoding state of the source.
      UTF8_REPLACEMENTS = {
        "\xE2\x80\x98".b => "'",   # U+2018 LEFT SINGLE QUOTATION MARK
        "\xE2\x80\x99".b => "'",   # U+2019 RIGHT SINGLE QUOTATION MARK
        "\xE2\x80\x9A".b => "'",   # U+201A SINGLE LOW-9 QUOTATION MARK
        "\xE2\x80\x9B".b => "'",   # U+201B SINGLE HIGH-REVERSED-9 QUOTATION MARK
        "\xE2\x80\x9C".b => '"',   # U+201C LEFT DOUBLE QUOTATION MARK
        "\xE2\x80\x9D".b => '"',   # U+201D RIGHT DOUBLE QUOTATION MARK
        "\xE2\x80\x9E".b => '"',   # U+201E DOUBLE LOW-9 QUOTATION MARK
        "\xE2\x80\x93".b => "-",   # U+2013 EN DASH
        "\xE2\x80\x94".b => "-",   # U+2014 EM DASH
        "\xE2\x80\x95".b => "-",   # U+2015 HORIZONTAL BAR
        "\xE2\x80\xA6".b => "...", # U+2026 HORIZONTAL ELLIPSIS
        "\xC2\xA0".b     => " ",   # U+00A0 NO-BREAK SPACE
        # Typographic spaces in the U+2000–U+200A range plus the line/para
        # separators. Word docs sprinkle these in liberally and SAS chokes
        # with `ERROR 217-322: Invalid statement due to first character
        # being unprintable`.
        "\xE2\x80\x80".b => " ",   # U+2000 EN QUAD
        "\xE2\x80\x81".b => " ",   # U+2001 EM QUAD
        "\xE2\x80\x82".b => " ",   # U+2002 EN SPACE
        "\xE2\x80\x83".b => " ",   # U+2003 EM SPACE
        "\xE2\x80\x84".b => " ",   # U+2004 THREE-PER-EM SPACE
        "\xE2\x80\x85".b => " ",   # U+2005 FOUR-PER-EM SPACE
        "\xE2\x80\x86".b => " ",   # U+2006 SIX-PER-EM SPACE
        "\xE2\x80\x87".b => " ",   # U+2007 FIGURE SPACE
        "\xE2\x80\x88".b => " ",   # U+2008 PUNCTUATION SPACE
        "\xE2\x80\x89".b => " ",   # U+2009 THIN SPACE
        "\xE2\x80\x8A".b => " ",   # U+200A HAIR SPACE
        "\xE2\x80\xA8".b => "\n",  # U+2028 LINE SEPARATOR
        "\xE2\x80\xA9".b => "\n",  # U+2029 PARAGRAPH SEPARATOR
        # Mac Roman 0xD0–0xD5 misread as Win-1252 → Latin-1 letters.
        # Mac OS Roman uses these byte slots for smart punctuation; when
        # `SasLinter#read_source` interprets a Mac-Roman-authored file
        # as Win-1252 it produces these spurious Latin-1 letters in the
        # post-transcode UTF-8. A typical SAS source corpus (English,
        # with documents that round-tripped through Word on Mac) shows
        # this as Latin-1 letters Ð / Ò / Ó / Ô / Õ standing in for
        # smart-punctuation glyphs.
        #
        # Skipping U+00D1 (Ñ) since it has too much legitimate Spanish-
        # name traffic to safely auto-replace.
        "\xC3\x90".b     => "-",   # U+00D0 Ð (Mac Roman: en dash)
        "\xC3\x92".b     => '"',   # U+00D2 Ò (Mac Roman: left double quote)
        "\xC3\x93".b     => '"',   # U+00D3 Ó (Mac Roman: right double quote)
        "\xC3\x94".b     => "'",   # U+00D4 Ô (Mac Roman: left single quote)
        "\xC3\x95".b     => "'",   # U+00D5 Õ (Mac Roman: right single quote)
      }.freeze

      # Map of single Windows-1252 bytes (0x80-0x9F range, plus 0xA0)
      # to their ASCII replacement. These bytes are invalid as
      # standalone UTF-8 but are how Word documents on legacy Windows
      # render the same characters covered by UTF8_REPLACEMENTS above.
      # Only applied to bytes that are *not* part of a valid UTF-8
      # sequence in context.
      #
      # 0x85 (HORIZONTAL ELLIPSIS) is intentionally absent. In real-world
      # SAS source corpora a standalone 0x85 is overwhelmingly a corrupted
      # Latin-1 letter inside a name (e.g. `\x85` standing in for `Ö`,
      # `Á`, etc.), not a real ellipsis. Mapping it to `...` would corrupt
      # those names. Recovering the proper letter is data-loss recovery
      # and belongs in a separate, source-specific fix configured via the
      # user `replacements:` map.
      BYTE_REPLACEMENTS = {
        0x82 => "'",   # SINGLE LOW-9 QUOTATION MARK
        0x91 => "'",   # LEFT SINGLE QUOTATION MARK
        0x92 => "'",   # RIGHT SINGLE QUOTATION MARK
        0x93 => '"',   # LEFT DOUBLE QUOTATION MARK
        0x94 => '"',   # RIGHT DOUBLE QUOTATION MARK
        0x96 => "-",   # EN DASH
        0x97 => "-",   # EM DASH
        0xA0 => " ",   # NO-BREAK SPACE
      }.freeze

      def self.supports_autofix?
        true
      end

      def self.from_config(opts = {})
        opts = opts.transform_keys(&:to_s)
        replacements = (opts["replacements"] || {}).to_h { |k, v| [k.to_s, v.to_s] }
        new(
          use_defaults: opts.fetch("use_defaults", false) ? true : false,
          replacements: replacements,
          autofix: opts["autofix"] ? true : false
        )
      end

      attr_reader :replacements, :use_defaults

      def initialize(use_defaults: false, replacements: {}, autofix: false)
        super(autofix: autofix)
        @use_defaults = use_defaults
        @replacements = replacements
      end

      def check(_tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless source

        findings = []
        findings.concat(default_findings(source, path: path)) if @use_defaults
        findings.concat(replacement_findings(source, path: path)) unless @replacements.empty?
        findings
      end

      def autofix(source)
        # User `replacements:` run FIRST so a project-specific pattern
        # can target byte sequences the canonical defaults would
        # otherwise consume. The motivating case: a SAS source corpus
        # has stray `\x85` bytes inside surnames (a corrupted Latin-1
        # letter) that `SasLinter#read_source` transcodes to
        # `\xE2\x80\xA6` (the UTF-8 ellipsis); a project-specific
        # `"M…LLER": "MÖLLER"` entry only fires if it sees those bytes
        # BEFORE the canonical map rewrites them to `...`.
        #
        # `.b` is required on every side of the `gsub` so mismatched
        # encodings can't blow up `String#gsub` with
        # `Encoding::CompatibilityError`. `source` arrives from
        # `lint_file` as UTF-8; `@replacements` keys/values from YAML
        # are UTF-8; `apply_canonical_fix` returns ASCII-8BIT.
        # Either combination raises when a multi-byte pattern
        # actually matches. `.b` returns a binary-encoded duplicate
        # without altering bytes, so the substitution stays byte-
        # faithful regardless of which direction the mismatch goes.
        step1 = @replacements.inject(source.b) { |s, (from, to)| s.gsub(from.b, to.b) }
        @use_defaults ? apply_canonical_fix(step1) : step1
      end

      # Walk `source` as a byte stream applying UTF8_REPLACEMENTS and
      # BYTE_REPLACEMENTS. A Win-1252 byte is replaced only when it's
      # not already part of a valid UTF-8 multibyte sequence — so
      # `M\xC3\x96LLER` (the Ö in `MÖLLER`) survives, but a standalone
      # `\x96` becomes `-`. Returns ASCII-8BIT.
      def apply_canonical_fix(source)
        bytes = source.bytes
        out = String.new(encoding: Encoding::BINARY)
        i = 0
        n = bytes.length

        while i < n
          b = bytes[i]

          if b < 0x80
            out << b
            i += 1
            next
          end

          seq_len = utf8_sequence_length(bytes, i, n)
          if seq_len.positive?
            seq = bytes[i, seq_len].pack("C*")
            replacement = UTF8_REPLACEMENTS[seq]
            out << (replacement ? replacement.b : seq)
            i += seq_len
          else
            replacement = BYTE_REPLACEMENTS[b]
            out << (replacement ? replacement.b : b)
            i += 1
          end
        end

        out
      end

      private

      # Walk the source byte-by-byte. For every byte / sequence in
      # the canonical replacement table, emit a finding tagged with
      # its line:column.
      def default_findings(source, path:)
        findings = []
        bytes = source.b.bytes
        line = 1
        col = 1
        i = 0
        n = bytes.length

        while i < n
          b = bytes[i]

          if b < 0x80
            if b == 0x0A
              line += 1
              col = 1
            else
              col += 1
            end
            i += 1
            next
          end

          seq_len = utf8_sequence_length(bytes, i, n)
          if seq_len.positive?
            seq = bytes[i, seq_len].pack("C*")
            if (replacement = UTF8_REPLACEMENTS[seq])
              findings << finding(
                line: line, column: col,
                message: "UTF-8 #{format('U+%04X', codepoint(seq))} -> #{replacement.inspect}" \
                         "#{autofix? ? ' (autofixed)' : ''}",
                path: path
              )
            end
            col += 1
            i += seq_len
          else
            if (replacement = BYTE_REPLACEMENTS[b])
              findings << finding(
                line: line, column: col,
                message: "Windows-1252 0x#{format('%02X', b)} -> #{replacement.inspect}" \
                         "#{autofix? ? ' (autofixed)' : ''}",
                path: path
              )
            end
            col += 1
            i += 1
          end
        end
        findings
      end

      def replacement_findings(source, path:)
        findings = []
        source.each_line.with_index do |line, line_idx|
          chomped = line.sub(/\r?\n\z/, "")
          @replacements.each do |from, to|
            search_from = 0
            while (idx = chomped.index(from, search_from))
              findings << finding(
                line: line_idx + 1,
                column: idx + 1,
                message: "found #{from.inspect}#{autofix? ? " → #{to.inspect} (autofixed)" : ' (no autofix)'}",
                path: path
              )
              search_from = idx + from.length
            end
          end
        end
        findings
      end

      # `seq` is ASCII-8BIT (from `pack("C*")`); `encode("UTF-8")` on a
      # binary string replaces every byte ≥ 0x80 with U+FFFD before
      # `codepoints` runs. The bytes are already a valid UTF-8 sequence
      # by construction (caller checked `utf8_sequence_length`), so
      # reinterpret rather than transcode.
      def codepoint(seq)
        seq.dup.force_encoding("UTF-8").codepoints.first
      end

      # Returns the length (1-4) of a valid UTF-8 sequence starting
      # at `bytes[i]`, or 0 if the bytes there aren't a valid UTF-8
      # character. The 1-byte case (ASCII) is handled by the caller
      # before this is invoked, so we only return ≥2 here.
      def utf8_sequence_length(bytes, i, n)
        b = bytes[i]
        return 0 if b < 0xC2
        return valid_continuation?(bytes, i + 1, n) ? 2 : 0 if b < 0xE0
        if b < 0xF0
          return valid_continuation?(bytes, i + 1, n) && valid_continuation?(bytes, i + 2, n) ? 3 : 0
        end
        if b < 0xF5 &&
           valid_continuation?(bytes, i + 1, n) &&
           valid_continuation?(bytes, i + 2, n) &&
           valid_continuation?(bytes, i + 3, n)
          return 4
        end

        0
      end

      def valid_continuation?(bytes, i, n)
        return false if i >= n

        b = bytes[i]
        b >= 0x80 && b < 0xC0
      end
    end
  end
end
