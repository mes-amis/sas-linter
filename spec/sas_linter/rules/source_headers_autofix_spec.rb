# frozen_string_literal: true

require "spec_helper"
require "sas_linter"

# End-to-end coverage for the `source_headers` rule's autofix path —
# every fixture pair captures one shape of broken-or-not 90-char
# `**...**;` header text and pins the rewritten output, so regressions
# in either the broken-line detector or the rewrite_line wrapper
# surface as a spec failure rather than as a silent diff.
RSpec.describe SasLinter::Rules::SourceHeaders do
  let(:fixture_dir) { File.join(__dir__, "..", "..", "fixtures", "source_headers_autofix") }
  let(:rule) { described_class.new(autofix: true) }

  def load_fixture(name)
    File.binread(File.join(fixture_dir, "#{name}.sas"))
  end

  # Public-facing autofix entry point — calls the rule the same way
  # SasLinter#lint_with_fixes does, so test failures map to user-
  # visible behavior.
  def fix(src)
    rule.autofix(src)
  end

  describe "#autofix" do
    context "when the header lines are already self-terminating" do
      it "leaves the source untouched" do
        src = load_fixture("already_correct")

        expect(fix(src)).to eq(src)
      end
    end

    context "when every header line is missing its trailing `;`" do
      it "terminates only the asterisk separator rows; header lines lex as one " \
         "multi-line comment closed by the next separator and need no rewrap" do
        src = load_fixture("missing_terminators")
        out = fix(src)

        # Asterisk rows get a `;` so the lexer sees them as null statements
        # rather than the start of an unbounded comment.
        expect(out).to include("**************************************************************************************;\n")
        # Body code is now lexed correctly (was previously eaten as comment).
        expect(out).to include("data one; set have;\n")
        # Header prose lines stay as-is — the lexer treats them as part of
        # one comment block bounded by the asterisk separators.
        expect(out).to include("**  PROGRAM:          BAD.TXT\n")
        expect(out).to include("**  PURPOSE:          fix me\n")
      end
    end

    context "when a header line has an inline `;` mid-prose" do
      it "preserves the inline `;` and appends `**;` so the lexer's predictive " \
         "`**...**;` recognition consumes the whole line as one comment token" do
        src = load_fixture("inline_semi_in_header")
        out = fix(src)

        expect(out).to include("**  CHECKED BY:       First Reviewer; Second Reviewer                                  **;")
      end
    end

    context "when a header continuation line lost its `**` prefix" do
      it "re-prefixes it with `**` and terminates with `**;`" do
        src = load_fixture("continuation_line")
        out = fix(src)

        expect(out).to match(/^\*\*  CHECK WITH AUTHOR FOR OTHERS\s+\*\*;$/)
      end
    end

    context "when the header contains tab characters" do
      it "expands them to 4 spaces before any other processing" do
        src = load_fixture("tabs_in_header")
        out = fix(src)

        expect(out).not_to include("\t")
        # Each tab becomes exactly 4 spaces.
        expect(out).to include("**    PROGRAM:    TAB_FILE.TXT")
      end
    end

    context "when a SAS body line ends with an inline `**` comment" do
      it "leaves the code line completely untouched (the false-positive case)" do
        src = load_fixture("body_inline_comment")
        out = fix(src)

        expect(out).to include("B1 = B1; **Variant A;\n")
        expect(out).to include("B2 = B2; **Variant B;\n")
      end
    end

    context "when a `**` line has a trailing extra `;` (null statement after a valid comment)" do
      it "leaves it alone — `** Section A; *** ... ***;;` is two valid comments + a null `;`" do
        src = load_fixture("null_statement_after_comment")
        out = fix(src)

        expect(out).to include("** Section A; *** Note about related items handled elsewhere. ***;;\n")
      end
    end

    context "when a `**` line has two valid comments on it separated by `;`" do
      it "does not flag it — `**  A  **; **  B  **;` is two valid SAS comments, not broken" do
        src = load_fixture("chained_two_comments_one_line")
        out = fix(src)

        expect(out).to include("**  VARIABLE ASSIGNMENTS  **; **  PUT YOUR VARIABLES ON THE RIGHT-HAND SIDE HERE  **;")
      end
    end

    context "when body code is sandwiched between `**` marker comments without a data step" do
      it "does not treat the body assignment as a header continuation line" do
        src = load_fixture("body_code_no_data_step")
        out = fix(src)

        expect(out).to include("A=0;\n")
        expect(out).to include("b=0;\n")
      end
    end

    context "when a `**` marker line appears between body code lines (not a continuation)" do
      it "does not treat surrounding code as continuation lines" do
        src = load_fixture("body_marker_between_code")
        out = fix(src)

        expect(out).to include("xVar = xVar;\n")
        expect(out).not_to include("**  xVar = xVar")
      end
    end

    context "when a narrative `*` comment legitimately wraps to a non-`**` next line" do
      it "leaves both lines untouched — the comment closes correctly across the line break" do
        src = load_fixture("narrative_multiline_comment")
        out = fix(src)

        expect(out).to include("*** Sum the number of contributing components.\n")
        expect(out).to include("Maximum is 4, but is 2 in the short form because two components are dropped;\n")
      end
    end

    context "when a narrative wrap appears in a fragment with no data/proc keyword" do
      it "still leaves the comment alone — closing line is non-`**` prose, not a header box" do
        src = load_fixture("narrative_comment_no_data_step")
        out = fix(src)

        expect(out).to include("*** Sum the number of contributing components.\n")
        expect(out).to include("Maximum is 4, but is 2 in the short form because two components are dropped;\n")
        # And the closing prose stays as-is (must not become live identifier).
        expect(out).not_to include("**  Maximum is 4")
      end
    end

    context "when the result is fed back through .fix" do
      it "is idempotent — second pass changes nothing" do
        src = load_fixture("missing_terminators")
        first  = fix(src)
        second = fix(first)

        expect(second).to eq(first)
      end
    end

    context "when the source has stray non-UTF-8 bytes (e.g. Word smart quotes)" do
      it "does not raise — it scrubs invalid bytes through the lexer call only" do
        # 0x93 is a Windows-1252 left double quote — invalid UTF-8 alone.
        # Constructed inline because fixture files must round-trip through
        # the editor; we don't want a binary-only fixture in the repo.
        src = (+"****************************************************************************************;\n" \
               "**  PROGRAM:          BAD\x93FILE.TXT                                                   **;\n" \
               "****************************************************************************************;\n" \
               "data one; set have;\nrun;\n").b

        expect { fix(src) }.not_to raise_error
      end
    end

    context "when the lexer reports the fixed source still has DEFAULT-channel IDENTIFIERs in `**` lines" do
      it "produces a source the lexer treats as fully-commented in the header region" do
        src = load_fixture("inline_semi_in_header")
        out = fix(src)

        expect(rule.broken_header_lines(out)).to be_empty
      end
    end
  end
end
