# frozen_string_literal: true

class SasLinter
  class Formatter
    BINARY_OP_NAMES = %w[
      ASSIGN PLUS MINUS STAR FSLASH STAR2
      LT LE GT GE NE LTGT GTLT
      AMP PIPE PIPE2 EXCL EXCL2 BPIPE BPIPE2 SOUNDS_LIKE
    ].freeze
    UNARY_CANDIDATE_NAMES = %w[PLUS MINUS].freeze
    NO_SPACE_BEFORE_NAMES = %w[SEMI COMMA RPAREN RBRACK].freeze
    VALUE_ENDING_NAMES    = %w[
      IDENTIFIER INTEGER_LITERAL FLOAT_LITERAL FLOAT_EXPONENT_LITERAL
      STRING_LITERAL NAME_LITERAL DATE_LITERAL TIME_LITERAL DATE_TIME_LITERAL
      HEX_STRING_LITERAL BIT_TESTING_LITERAL MACRO_VAR_RESOLVE MACRO_IDENTIFIER
      STRING_EXPR_END BIT_TESTING_LITERAL_EXPR_END DATE_LITERAL_EXPR_END
      DATE_TIME_LITERAL_EXPR_END HEX_STRING_LITERAL_EXPR_END NAME_LITERAL_EXPR_END
      TIME_LITERAL_EXPR_END RPAREN RBRACK
    ].freeze
    COMMA_NAMES     = %w[COMMA].freeze
    DATA_PROC_NAMES = %w[KW_DATA KW_PROC].freeze
    DO_NAMES        = %w[KW_DO].freeze
    END_NAMES       = %w[KW_END].freeze
    RUN_QUIT_NAMES  = %w[KW_RUN KW_QUIT].freeze
    SEMI_NAMES      = %w[SEMI].freeze

    def self.from_config(config)
      config = (config || {}).transform_keys(&:to_s)
      fmt = (config["format"] || {}).transform_keys(&:to_s)

      keywords = fmt.fetch("keywords", "preserve").to_sym
      unless %i[preserve upper lower].include?(keywords)
        raise ArgumentError,
              "format.keywords must be 'preserve', 'upper', or 'lower' (got '#{keywords}')"
      end

      operator_spacing = fmt.key?("operator_spacing") ? !!fmt["operator_spacing"] : false

      raw_width = fmt["indent_width"]
      indent_width = case raw_width
                     when nil, false then nil
                     else
                       w = Integer(raw_width)
                       w > 0 ? w : nil
                     end

      new(keywords: keywords, operator_spacing: operator_spacing, indent_width: indent_width)
    end

    def initialize(keywords: :preserve, operator_spacing: false, indent_width: nil)
      @keywords = keywords
      @operator_spacing = operator_spacing
      @indent_width = indent_width
    end

    def format(source)
      return source if noop?

      lexer = SasLexer::Lexer.new
      all_tokens = begin
        lexer.tokenize(source)
      ensure
        lexer.free
      end

      result = reconstruct(all_tokens)
      result = apply_indentation(result, all_tokens) if @indent_width
      result
    end

    private

    def noop?
      @keywords == :preserve && !@operator_spacing && @indent_width.nil?
    end

    # --- Type sets (built lazily from sas-lexer vocabulary) ---

    def type_set(names)
      tt = SasLexer::Lexer::TokenType
      names.filter_map { |n| tt.const_get(n) if tt.const_defined?(n) }.to_set
    end

    def keyword_types
      @keyword_types ||= SasLexer::Lexer::TokenType.constants
        .select { |c| c.to_s.start_with?("KW_", "KWM_") }
        .map { |c| SasLexer::Lexer::TokenType.const_get(c) }
        .to_set
    end

    def binary_op_types    = @binary_op_types    ||= type_set(BINARY_OP_NAMES)
    def unary_cand_types   = @unary_cand_types   ||= type_set(UNARY_CANDIDATE_NAMES)
    def no_sp_before_types = @no_sp_before_types ||= type_set(NO_SPACE_BEFORE_NAMES)
    def value_ending_types = @value_ending_types ||= type_set(VALUE_ENDING_NAMES)
    def comma_types        = @comma_types        ||= type_set(COMMA_NAMES)
    def data_proc_types    = @data_proc_types    ||= type_set(DATA_PROC_NAMES)
    def do_types           = @do_types           ||= type_set(DO_NAMES)
    def end_types          = @end_types          ||= type_set(END_NAMES)
    def run_quit_types     = @run_quit_types     ||= type_set(RUN_QUIT_NAMES)
    def semi_types         = @semi_types         ||= type_set(SEMI_NAMES)

    # --- Reconstruction (keyword casing + operator spacing) ---

    def apply_casing(token)
      text = token[:text]
      return text if @keywords == :preserve

      default_ch = SasLexer::Lexer::TokenChannel::DEFAULT
      return text unless token[:channel] == default_ch && keyword_types.include?(token[:type])

      @keywords == :upper ? text.upcase : text.downcase
    end

    # Partition all_tokens into [{gap:, tok:}] segments where gap holds the
    # non-DEFAULT tokens preceding tok, and tok is a DEFAULT-channel token.
    def segmentize(all_tokens)
      default_ch = SasLexer::Lexer::TokenChannel::DEFAULT
      segments = []
      gap = []
      all_tokens.each do |t|
        if t[:channel] == default_ch
          segments << { gap: gap, tok: t }
          gap = []
        else
          gap << t
        end
      end
      segments << { gap: gap, tok: nil } unless gap.empty?
      segments
    end

    def reconstruct(all_tokens)
      segments = segmentize(all_tokens)
      result = +""

      segments.each_with_index do |seg, idx|
        prev_prev = idx > 1 ? segments[idx - 2][:tok] : nil
        prev      = idx > 0 ? segments[idx - 1][:tok] : nil
        cur       = seg[:tok]
        gap_text  = seg[:gap].map { |t| t[:text] }.join

        if @operator_spacing && prev && cur && !gap_text.include?("\n")
          desired = gap_desired(prev_prev, prev, cur)
          result << (desired.nil? ? gap_text : desired)
        else
          result << gap_text
        end

        result << apply_casing(cur) if cur
      end

      result
    end

    # Returns the desired whitespace between two same-line DEFAULT tokens:
    #   nil  → leave unchanged
    #   ""   → no space
    #   " "  → exactly one space
    #
    # Three consecutive DEFAULT tokens are provided so unary PLUS/MINUS can be
    # distinguished from binary: a PLUS/MINUS is binary only when its preceding
    # token is a value-ending type (identifier, literal, or closing bracket).
    def gap_desired(prev_prev_tok, prev_tok, next_tok)
      pt  = prev_tok[:type]
      nt  = next_tok[:type]
      ppt = prev_prev_tok&.[](:type)

      return ""  if no_sp_before_types.include?(nt)
      return " " if comma_types.include?(pt)

      # Space after binary operator — but not after a unary +/-
      if binary_op_types.include?(pt)
        if unary_cand_types.include?(pt) && (ppt.nil? || !value_ending_types.include?(ppt))
          return nil
        end
        return " "
      end

      # Space before binary operator — but not before a unary +/-
      if binary_op_types.include?(nt)
        return nil if unary_cand_types.include?(nt) && !value_ending_types.include?(pt)

        return " "
      end

      nil
    end

    # --- Indentation ---

    # Walk all_tokens and assign an indent level to each source line.
    # Only the FIRST token on a given line determines its level (||= semantics).
    # Nesting rules:
    #   DATA / PROC → level 0; content after their SEMI → level 1
    #   DO          → content inside indented one further level
    #   END         → decrements level before assigning the END line's level
    #   RUN / QUIT  → resets to level 0
    def compute_line_levels(all_tokens)
      default_ch = SasLexer::Lexer::TokenChannel::DEFAULT
      hidden_ch  = SasLexer::Lexer::TokenChannel::HIDDEN
      levels = {}
      level = 0
      after_data_proc = false

      all_tokens.each do |tok|
        next if tok[:channel] == hidden_ch

        line = tok[:start_line]
        type = tok[:type]

        unless tok[:channel] == default_ch
          levels[line] ||= level  # comment tokens — indent at current level
          next
        end

        if data_proc_types.include?(type)
          level = 0
          after_data_proc = true
          levels[line] ||= level
        elsif run_quit_types.include?(type)
          level = 0
          after_data_proc = false
          levels[line] ||= level
        elsif do_types.include?(type)
          levels[line] ||= level
          level += 1
        elsif end_types.include?(type)
          level = [level - 1, 0].max
          levels[line] ||= level
        elsif semi_types.include?(type) && after_data_proc
          # Semicolon ends the DATA/PROC header — step body starts at level 1.
          # Don't re-assign the SEMI's line (already marked at level 0 by DATA/PROC).
          after_data_proc = false
          level = 1
        else
          levels[line] ||= level
        end
      end

      levels
    end

    # Re-indent each line of source using the computed per-line levels.
    # Lines with no token coverage (blank lines) are left unchanged.
    def apply_indentation(source, all_tokens)
      line_levels = compute_line_levels(all_tokens)

      source.each_line.with_index.map do |line, idx|
        lineno     = idx + 1
        line_level = line_levels[lineno]
        next line if line_level.nil?

        eol     = line.match(/\r?\n\z/)&.[](0) || ""
        body    = line[0...(line.length - eol.length)]
        stripped = body.lstrip
        next eol if stripped.empty?  # blank line — strip stray whitespace

        (" " * (@indent_width * line_level)) + stripped + eol
      end.join
    end
  end
end
