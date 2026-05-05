# frozen_string_literal: true

require "set"
require_relative "../../sas_linter"
require "sas_lexer"

class SasLinter
  module Rules
    # Restore the standard 90-char `**...**;` header convention to broken SAS
    # source files. Detects header lines that *look* like `**`-comments
    # but produce DEFAULT-channel tokens, and re-wraps them as proper
    # `**  ...  **;` rows.
    #
    # Working sources use a uniform 90-char-wide header where each
    # line is its own self-contained `*` comment statement:
    #
    #     ****************************************************************************************;
    #     **  PROGRAM:          ...                                                            **;
    #     **  BY:               ...                                                            **;
    #
    # Broken sources have lines that look like comments (start with
    # `**`) but produce DEFAULT-channel tokens. Two flavors:
    #
    #   A. Missing trailing `;` on every header line — the whole
    #      header is one giant unterminated `*` comment until the
    #      first inline `;` ends it, leaking the rest of that
    #      physical line and following lines onto DEFAULT.
    #
    #   B. Trailing `**;` is present but an inline `;` (e.g. a
    #      semicolon-separated list like `First Reviewer; Second
    #      Reviewer`) terminates the comment in the middle of the
    #      line — what follows the inline `;` ends up on DEFAULT
    #      even though the line *looks* terminated.
    #
    # Some files also have header continuation lines (text that
    # should be inside a `**` comment) that lost their `**` prefix
    # during a text-conversion step. Those are detected only inside
    # the file's leading header block — *before* the first KW_DATA /
    # KW_PROC token the lexer reports — so legitimate body code
    # sandwiched between `**` marker comments is left alone.
    #
    # Recognized config options:
    #   autofix: true | false   (default: false)
    class SourceHeaders < Rule
      rule_id :source_headers
      description "Header lines look like `**`-comments but lex as code; will be re-wrapped."
      severity :warning

      TARGET_WIDTH = 90
      PAD_TO       = TARGET_WIDTH - 3 # leave 3 chars for trailing `**;`

      DEFAULT_CHANNEL = SasLexer::Lexer::TokenChannel::DEFAULT
      KW_DATA         = SasLexer::Lexer::TokenType::KW_DATA
      KW_PROC         = SasLexer::Lexer::TokenType.const_get(:KW_PROC) if SasLexer::Lexer::TokenType.const_defined?(:KW_PROC)
      C_STYLE_COMMENT = SasLexer::Lexer::TokenType::C_STYLE_COMMENT
      IDENTIFIER      = SasLexer::Lexer::TokenType::IDENTIFIER
      SEMI            = SasLexer::Lexer::TokenType::SEMI
      ASSIGN          = SasLexer::Lexer::TokenType::ASSIGN

      def self.supports_autofix?
        true
      end

      def check(_tokens, path:, all_tokens: nil, source: nil) # rubocop:disable Lint/UnusedMethodArgument
        return [] unless source

        broken_header_lines(source).map do |line_idx|
          finding(
            line: line_idx + 1,
            column: 1,
            message: "broken header line#{autofix? ? ' (autofixed)' : ''}",
            path: path
          )
        end
      end

      def autofix(source)
        # Step 0: expand any tab characters to 4 spaces. Tabs in
        # SAS source headers often come from Word docs, and
        # break the column-alignment of the header box. Doing this
        # first means every downstream check sees consistent column
        # offsets.
        text = source.gsub("\t", "    ")
        10.times do
          tokens = tokenize(text)
          skip   = c_comment_lines(tokens)
          bad    = broken_lines_for(text, tokens, skip) |
                   asterisk_rows_missing_semi_for(text, skip)
          break if bad.empty?

          text = rewrite(text, bad)
        end
        text
      end

      # 0-indexed line numbers the lexer thinks are broken header
      # text in `source`. Public so the rule's `check` can produce
      # findings without re-tokenizing on its own.
      def broken_header_lines(source)
        tokens = tokenize(source)
        broken_lines_for(source, tokens, c_comment_lines(tokens))
      end

      private

      # Lex `text`. The Rust lexer demands valid UTF-8; some legacy SAS
      # sources ship with stray Windows-1252 bytes (smart quotes). We
      # make a UTF-8-safe copy for the lexer call, then operate on
      # the original byte string for offset math — the byte positions
      # line up because we only replace bytes, never insert or delete.
      def tokenize(text)
        utf8 = text.dup.force_encoding(Encoding::UTF_8)
        utf8 = utf8.scrub("?") unless utf8.valid_encoding?
        lexer = SasLexer::Lexer.new
        begin
          lexer.tokenize(utf8)
        ensure
          lexer.free
        end
      end

      # 0-indexed line number of the first body keyword (KW_DATA /
      # KW_PROC). Lines at or after this cutoff are body code, not
      # header. Falls back to `total_lines` for fragments that have
      # no data/proc step.
      def header_cutoff_line(tokens, total_lines)
        first_body = tokens.find do |t|
          t[:type] == KW_DATA || (KW_PROC && t[:type] == KW_PROC)
        end
        first_body ? first_body[:start_line] - 1 : total_lines
      end

      # Set of 0-indexed line numbers that fall inside a `/* ... */`
      # C_STYLE_COMMENT token. Legacy SAS sources sometimes embed
      # large code blocks in such comments; header repair must skip
      # those lines.
      def c_comment_lines(tokens)
        lines = Set.new
        tokens.each do |tok|
          next unless tok[:type] == C_STYLE_COMMENT

          ((tok[:start_line] - 1)..(tok[:end_line] - 1)).each { |ln| lines << ln }
        end
        lines
      end

      # A line is "prose-only" iff its DEFAULT-channel tokens contain
      # no SAS-syntax control tokens (no `;`, no `=`). Real body code
      # always has at least one of those; prose ("CHECK WITH AUTHOR
      # FOR OTHERS") has neither.
      def prose_only_line?(tokens, line_idx)
        saw_default = false
        tokens.each do |tok|
          next unless tok[:start_line] - 1 == line_idx
          next unless tok[:channel] == DEFAULT_CHANNEL

          saw_default = true
          return false if tok[:type] == SEMI || tok[:type] == ASSIGN
        end
        saw_default
      end

      def broken_lines_for(text, tokens, skip_lines)
        lines     = text.split("\n", -1)
        cutoff_ln = header_cutoff_line(tokens, lines.length)

        bad = Set.new

        # Pattern A: the Rust lexer reports a DEFAULT-channel
        # IDENTIFIER on a line that's otherwise a `**` comment block.
        # IDENTIFIERs are the diagnostic shape — when prose (e.g. a
        # list of reviewers separated by `;`) leaks past an inline
        # `;` it lexes as variable references. A bare DEFAULT SEMI
        # from `**A; **B; ;` is a harmless null statement and must
        # not flag the line.
        default_lines = Set.new
        tokens.each do |tok|
          next unless tok[:channel] == DEFAULT_CHANNEL && tok[:type] == IDENTIFIER

          default_lines << (tok[:start_line] - 1)
        end

        default_lines.each do |i|
          next if skip_lines.include?(i)

          line = lines[i] or next
          if line.lstrip.start_with?("**")
            # Skip lines that already look properly terminated
            # `**  ...  **;`. If the lexer reports default-channel
            # IDENTIFIERs on such a line, it's almost always because
            # something *upstream* is unterminated (e.g. a missing
            # `;` after `value foo 0='x' 1='y'`) — re-padding this
            # line won't fix the upstream problem.
            next if line.rstrip.end_with?("**;")

            bad << i
          elsif i < cutoff_ln
            prev = nearest_nonblank(lines, i, -1)
            nxt  = nearest_nonblank(lines, i, +1)
            next unless prev&.lstrip&.start_with?("**") && nxt&.lstrip&.start_with?("**")
            # Stricter than just "sandwiched": require the line itself
            # to be prose only. This protects body code (`A=0;`,
            # `if x then y;`) that happens to sit between `**` marker
            # comments.
            bad << i if prose_only_line?(tokens, i)
          end
        end

        # No textual heuristic for "header-shaped lines without
        # trailing `;`" (formerly Pattern C). The SAS lexer accepts
        # plenty of shapes the heuristic flagged —
        # `** START OF SAS CODE **` (no `;`),
        # `**  REVISION DATES:  03/15/12; 10/07/2025  **;` (inline
        # `;` in prose with proper end terminator), `**...**:`
        # (colon instead of semicolon) — and Pattern A above already
        # catches every line where default-channel code actually
        # leaks. Cosmetic-only re-padding is not worth the diff churn.

        bad
      end

      def nearest_nonblank(lines, from, step)
        i = from + step
        while i >= 0 && i < lines.length
          return lines[i] unless lines[i].strip.empty?

          i += step
        end
        nil
      end

      def asterisk_rows_missing_semi_for(text, skip_lines)
        bad = Set.new
        text.split("\n", -1).each_with_index do |line, i|
          next if skip_lines.include?(i)

          bad << i if line.strip.match?(/\A\*+\z/) && !line.rstrip.end_with?(";")
        end
        bad
      end

      def rewrite(text, bad)
        lines = text.split("\n", -1)
        out = []
        lines.each_with_index do |line, i|
          if bad.include?(i)
            out.concat(rewrite_line(line))
          else
            out << line
          end
        end
        out.join("\n")
      end

      # Rewrite one broken line into one or more proper `**  ...  **;`
      # lines.
      def rewrite_line(line)
        stripped = line.rstrip
        return ["#{stripped};"] if stripped.match?(/\A\*+\z/)

        # Continuation line missing `**` prefix — re-add it.
        stripped = "**  #{stripped.lstrip}" unless stripped.start_with?("**")

        # Strip an existing trailing `**;` or `;` so we re-pad
        # consistently.
        stripped = if stripped.end_with?("**;")
                     stripped[0..-4].rstrip
                   elsif stripped.end_with?(";")
                     stripped[0..-2].rstrip
                   else
                     stripped
                   end

        # Split only on `\s+\*\*\s+` — the signature of two
        # `**...**;` comments that lost their line break. Inline `;`
        # mid-prose is preserved as-is: once we append a trailing
        # `**;`, the SAS lexer's predictive `**...**;` recognition
        # consumes the whole line as one COMMENT-channel token, so
        # the inline `;` no longer closes the comment early.
        segments = stripped.split(/\s+\*\*\s+/)
        segments.each_with_index.map do |seg, idx|
          text = idx.zero? ? seg.rstrip : "**  #{seg.strip}"
          text = "**  #{text}" unless text.start_with?("**")
          text = text.ljust(PAD_TO) if text.length < PAD_TO
          "#{text}**;"
        end
      end
    end
  end
end
