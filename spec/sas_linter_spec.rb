# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe SasLinter do
  let(:lints_path) { File.join(__dir__, "fixtures", "lints") }

  # Each lint subject directory holds a `lint.sas` (demonstrates the bug) and
  # a `clean.sas` (the same shape, fixed). These helpers keep test bodies short.
  def lint_fixture(subject)
    File.join(lints_path, subject, "lint.sas")
  end

  def clean_fixture(subject)
    File.join(lints_path, subject, "clean.sas")
  end

  describe "rule registry" do
    it "registers UnreachableInnerBranchValue under :unreachable_inner_branch_value" do
      expect(SasLinter::Rule.fetch(:unreachable_inner_branch_value))
        .to eq(SasLinter::Rules::UnreachableInnerBranchValue)
    end

    it "registers MalformedIfCondition under :malformed_if_condition" do
      expect(SasLinter::Rule.fetch(:malformed_if_condition))
        .to eq(SasLinter::Rules::MalformedIfCondition)
    end

    it "registers MissingAssignmentSemicolon under :missing_assignment_semicolon" do
      expect(SasLinter::Rule.fetch(:missing_assignment_semicolon))
        .to eq(SasLinter::Rules::MissingAssignmentSemicolon)
    end

    it "raises ArgumentError for an unknown rule id" do
      expect { SasLinter::Rule.fetch(:does_not_exist) }
        .to raise_error(ArgumentError, /Unknown lint rule/)
    end
  end

  describe "malformed if condition" do
    let(:findings) do
      described_class.new(rules: [:malformed_if_condition]).lint_file(lint_fixture("malformed_if_condition"))
    end

    it "flags every malformed `if` shape with the right rule id" do
      expect(findings.map(&:rule).uniq).to eq([:malformed_if_condition])
      expect(findings.length).to eq(6)
    end

    it "flags two adjacent operands as a missing logical operator" do
      f = findings.find { |x| x.line == 1 }
      expect(f.column).to eq(11)
      expect(f.message).to include("missing operator before `A2`")
      expect(f.message).to include("`and`")
    end

    it "flags a binary operator with no right operand before `then`" do
      f = findings.find { |x| x.line == 2 }
      expect(f.column).to eq(11)
      expect(f.message).to include("`and`")
      expect(f.message).to include("no right operand")
    end

    it "flags a leading operator with no left operand" do
      f = findings.find { |x| x.line == 3 }
      expect(f.column).to eq(4)
      expect(f.message).to include("`=`")
      expect(f.message).to include("no left operand")
    end

    it "flags an empty condition between `if` and `then`" do
      f = findings.find { |x| x.line == 4 }
      expect(f.column).to eq(4)
      expect(f.message).to include("empty")
    end

    it "flags an orphan `then` (likely missing `if`)" do
      f = findings.find { |x| x.line == 5 }
      expect(f.column).to eq(8)
      expect(f.message).to include("`then` without")
      expect(f.message).to include("missing `if`")
    end

    it "flags an unbalanced opening paren" do
      f = findings.find { |x| x.line == 6 }
      expect(f.column).to eq(4)
      expect(f.message).to include("unbalanced")
    end

    it "produces no findings for a file of well-formed `if` conditions" do
      clean = described_class.new(rules: [:malformed_if_condition]).lint_file(clean_fixture("malformed_if_condition"))
      expect(clean).to be_empty
    end

    it "emits at most one finding per `if` even when one structural defect would " \
       "cascade through the state machine into adjacent unbalanced-paren / " \
       "orphan-then errors" do
      findings = described_class.new(rules: [:malformed_if_condition])
                                .lint_file(lint_fixture("malformed_if_condition_cascade"))

      # 3 `if`s on 3 lines, one defect each — exactly 3 findings.
      expect(findings.length).to eq(3)
      expect(findings.map(&:line)).to eq([1, 2, 3])

      # Line 1: `K2 in 0,1)` — missing `(` after `in`. Used to cascade
      # into "unbalanced `)`" + orphan `then`.
      expect(findings[0].message).to include("missing operator before `1`")
      # Line 2: unclosed `(` before `then` — flag at the offending `(`,
      # not at a downstream orphan `then`.
      expect(findings[1].message).to include("unbalanced `(`")
      # Line 3: stray `)` at depth 0 — flag the `)`, don't also flag
      # the following `then` as an orphan.
      expect(findings[2].message).to include("unbalanced `)`")
    end
  end

  describe "missing assignment semicolon" do
    let(:findings) do
      described_class.new(rules: [:missing_assignment_semicolon])
                     .lint_file(lint_fixture("missing_assignment_semicolon"))
    end

    it "flags an assignment whose `**` was meant to start an inline comment but " \
       "got parsed as exponentiation because the terminating `;` was omitted" do
      expect(findings.length).to eq(1)
      expect(findings[0].rule).to eq(:missing_assignment_semicolon)
      expect(findings[0].line).to eq(3)
      expect(findings[0].column).to eq(16)
      expect(findings[0].message).to include("missing `;`")
      expect(findings[0].message).to include("`**`")
    end

    it "produces no findings when every assignment terminates with `;` (and " \
       "legitimate exponentiation `Y ** 2` is left alone)" do
      clean = described_class.new(rules: [:missing_assignment_semicolon])
                             .lint_file(clean_fixture("missing_assignment_semicolon"))
      expect(clean).to be_empty
    end

    it "autofix inserts `;` after the RHS identifier — consuming one space when " \
       "there's room (preserving inline `**` alignment) or padding `; ` when " \
       "the gap is tight" do
      Tempfile.create(["mas_fix", ".sas"]) do |f|
        # B1 line has 5 spaces between RHS and `**` (consume one for `;`).
        # X  line has 1 space (need to inject `; ` so `**` keeps its space).
        f.write(File.read(File.join(lints_path, "missing_assignment_semicolon", "autofix.sas")))
        f.flush
        rule = SasLinter::Rules::MissingAssignmentSemicolon.new(autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)

        out = File.read(f.path)
        expect(out).to include("   B1 = B1;    **  Comatose;\n")
        expect(out).to include("   X  = X; **  Estimated Survival;\n")
      end
    end
  end

  describe "unreachable inner branch value" do
    it "flags inner `if VAR in (...)` values excluded by an enclosing outer guard" do
      findings = described_class.new.lint_file(lint_fixture("unreachable_inner"))

      expect(findings.length).to eq(1)
      expect(findings[0].rule).to eq(:unreachable_inner_branch_value)
      expect(findings[0].line).to eq(4)
      expect(findings[0].column).to eq(25)
      expect(findings[0].message).to include("value 7 for STAGE_VAR")
      expect(findings[0].message).to include("guard at line 1")
    end

    it "produces no findings when every inner value is in the outer guard set" do
      expect(described_class.new.lint_file(clean_fixture("unreachable_inner"))).to be_empty
    end

    it "flags `if VAR = N` and `if VAR eq N` inner checks against the outer guard" do
      findings = described_class.new.lint_file(lint_fixture("unreachable_inner_eq"))

      expect(findings.length).to eq(2)
      expect(findings[0].line).to eq(2)
      expect(findings[0].message).to include("value 5 for X")
      expect(findings[1].line).to eq(3)
      expect(findings[1].message).to include("value 4 for X")
    end

    it "produces no findings when `=`/`eq` values are within the outer guard" do
      expect(described_class.new.lint_file(clean_fixture("unreachable_inner_eq"))).to be_empty
    end
  end

  describe "identical if/else branches" do
    it "flags `if COND then S; else S;` when both bodies are identical" do
      findings = described_class.new.lint_file(lint_fixture("identical_if_else_branches"))

      expect(findings.length).to eq(2)
      expect(findings.map(&:rule).uniq).to eq([:identical_if_else_branches])
      expect(findings[0].line).to eq(1)
      expect(findings[0].message).to include("then NF1_2 = 0; else NF1_2 = 0")
      expect(findings[1].line).to eq(2)
      expect(findings[1].message).to include("then cOut = 5; else cOut = 5")
    end

    it "produces no findings when THEN and ELSE bodies differ" do
      expect(described_class.new.lint_file(clean_fixture("identical_if_else_branches"))).to be_empty
    end
  end

  describe "commented out guard" do
    it "flags `* if ... then do; ;` line comments that look like disabled validity guards" do
      findings = described_class.new.lint_file(lint_fixture("commented_out_guard"))

      expect(findings.length).to eq(1)
      expect(findings[0].rule).to eq(:commented_out_guard)
      expect(findings[0].line).to eq(2)
      expect(findings[0].message).to include("disabled validity guard")
    end

    it "does not flag plain narrative comments or non-guard `*` statements" do
      expect(described_class.new.lint_file(clean_fixture("commented_out_guard"))).to be_empty
    end
  end

  describe "choose one template" do
    it "flags the 'CHOOSE ONE OF THE BELOW STATEMENTS' banner in SAS line comments" do
      findings = described_class.new.lint_file(lint_fixture("choose_one_template"))

      banner_findings = findings.select { |f| f.rule == :choose_one_template }
      expect(banner_findings.length).to eq(1)
      expect(banner_findings[0].line).to eq(1)
      expect(banner_findings[0].message).to include("broken-by-default")
    end

    it "ignores the banner when it appears inside a /* */ block comment" do
      findings = described_class.new.lint_file(clean_fixture("choose_one_template"))
      expect(findings.select { |f| f.rule == :choose_one_template }).to be_empty
    end
  end

  describe "trailing whitespace" do
    it "flags every line with trailing spaces or tabs" do
      findings = described_class.new.lint_file(lint_fixture("trailing_whitespace"))
      ws = findings.select { |f| f.rule == :trailing_whitespace }
      expect(ws.map(&:line)).to eq([1, 2, 4, 5])
    end

    it "produces no findings on a file with no trailing whitespace" do
      expect(described_class.new.lint_file(clean_fixture("trailing_whitespace"))).to be_empty
    end

    it "leaves the file untouched when autofix is off (default)" do
      Tempfile.create(["tw", ".sas"]) do |f|
        f.write("if x = 1;   \nrun;\n")
        f.flush
        before = File.read(f.path)
        described_class.new.lint_file(f.path)
        expect(File.read(f.path)).to eq(before)
      end
    end

    it "rewrites the file when the rule is constructed with autofix: true" do
      Tempfile.create(["tw_fix", ".sas"]) do |f|
        f.write("if x = 1;   \nrun;\t\n")
        f.flush
        rule = SasLinter::Rules::TrailingWhitespace.new(autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq("if x = 1;\nrun;\n")
      end
    end

    it "preserves CRLF line endings while stripping trailing whitespace" do
      Tempfile.create(["tw_crlf", ".sas"]) do |f|
        f.write("if x = 1;   \r\nrun;\r\n")
        f.flush
        rule = SasLinter::Rules::TrailingWhitespace.new(autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq("if x = 1;\r\nrun;\r\n")
      end
    end

    it "honors `autofix: true` in the YAML config" do
      Tempfile.create(["tw_cfg", ".sas"]) do |f|
        f.write("if x = 1;   \nrun;\n")
        f.flush
        linter = described_class.from_config(
          "rules" => { "trailing_whitespace" => { "enabled" => true, "autofix" => true } }
        )
        linter.lint_file(f.path)
        expect(File.read(f.path)).to eq("if x = 1;\nrun;\n")
      end
    end
  end

  describe "tab expansion" do
    it "flags every tab character with its column" do
      findings = described_class.new.lint_file(lint_fixture("tab_expansion"))
      tabs = findings.select { |f| f.rule == :tab_expansion }
      expect(tabs.map { |f| [f.line, f.column] }).to eq([[1, 14], [2, 1], [3, 3]])
    end

    it "leaves the file untouched when autofix is off" do
      Tempfile.create(["tx", ".sas"]) do |f|
        f.write("if x;\tend;\n")
        f.flush
        before = File.read(f.path)
        described_class.new.lint_file(f.path)
        expect(File.read(f.path)).to eq(before)
      end
    end

    it "expands tabs to the next tab stop using the configured width" do
      Tempfile.create(["tx_fix", ".sas"]) do |f|
        # `if x = 1 then` is 13 chars → tab at col 13 fills to col 16 (3 spaces).
        # Leading tab at col 0 fills to col 4 (4 spaces).
        # `  ` + tab is at col 2 → fills to col 4 (2 spaces).
        f.write("if x = 1 then\tcOut = 0;\n\txVar = 5;\n  \tindent;\n")
        f.flush
        rule = SasLinter::Rules::TabExpansion.new(width: 4, autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq(
          "if x = 1 then   cOut = 0;\n    xVar = 5;\n    indent;\n"
        )
      end
    end

    it "uses width: 8 when nothing else is configured" do
      Tempfile.create(["tx_w8", ".sas"]) do |f|
        f.write("\tx;\n")
        f.flush
        rule = SasLinter::Rules::TabExpansion.new(autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq("        x;\n")
      end
    end

    it "honors `width: 4, autofix: true` from the YAML config" do
      Tempfile.create(["tx_cfg", ".sas"]) do |f|
        f.write("\tx;\n")
        f.flush
        linter = described_class.from_config(
          "rules" => { "tab_expansion" => { "enabled" => true, "width" => 4, "autofix" => true } }
        )
        linter.lint_file(f.path)
        expect(File.read(f.path)).to eq("    x;\n")
      end
    end

    it "rejects a non-positive width at construction time" do
      expect { SasLinter::Rules::TabExpansion.new(width: 0) }.to raise_error(ArgumentError)
    end
  end

  describe "encoding issues" do
    let(:smart_quote_map) do
      {
        "‘" => "'", "’" => "'",
        "“" => '"', "”" => '"',
        "—" => "--",
        "�" => "'"
      }
    end

    it "is a no-op when `replacements` is empty (the placeholder default)" do
      Tempfile.create(["enc_noop", ".sas"]) do |f|
        f.write("if x = ‘y’;\n")
        f.flush
        before = File.read(f.path)
        rule = SasLinter::Rules::EncodingIssues.new
        findings = described_class.new(rules: [rule]).lint_file(f.path)
        expect(findings).to be_empty
        expect(File.read(f.path)).to eq(before)
      end
    end

    it "flags every occurrence of every configured `from` string" do
      findings = described_class.new(
        rules: [SasLinter::Rules::EncodingIssues.new(replacements: smart_quote_map)]
      ).lint_file(lint_fixture("encoding_issues"))

      enc = findings.select { |f| f.rule == :encoding_issues }
      expect(enc.length).to eq(6) # ‘ ’ — “ ” �
      expect(enc.map(&:line).uniq.sort).to eq([1, 2, 3])
      expect(enc[0].message).to include("(no autofix)")
    end

    it "rewrites every match when autofix is enabled" do
      Tempfile.create(["enc_fix", ".sas"]) do |f|
        f.write(File.read(lint_fixture("encoding_issues")))
        f.flush
        rule = SasLinter::Rules::EncodingIssues.new(
          replacements: smart_quote_map, autofix: true
        )
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq(File.read(clean_fixture("encoding_issues")))
      end
    end

    it "honors `replacements` and `autofix` from the YAML config" do
      Tempfile.create(["enc_cfg", ".sas"]) do |f|
        f.write("if x = ‘y’;\n")
        f.flush
        linter = described_class.from_config(
          "rules" => {
            "encoding_issues" => {
              "enabled" => true,
              "autofix" => true,
              "replacements" => { "‘" => "'", "’" => "'" }
            }
          }
        )
        linter.lint_file(f.path)
        expect(File.read(f.path)).to eq("if x = 'y';\n")
      end
    end

    it "leaves the file untouched when autofix is off" do
      Tempfile.create(["enc_dry", ".sas"]) do |f|
        f.write("‘x’\n")
        f.flush
        before = File.read(f.path)
        rule = SasLinter::Rules::EncodingIssues.new(
          replacements: smart_quote_map, autofix: false
        )
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq(before)
      end
    end
  end

  describe "rule selection" do
    it "runs only the requested rules when `rules:` is given" do
      linter = described_class.new(rules: [:unreachable_inner_branch_value])
      expect(linter.lint_file(lint_fixture("identical_if_else_branches"))).to be_empty
    end
  end

  describe "configuration via YAML" do
    it "skips a rule whose config block has `enabled: false`" do
      linter = described_class.from_config(
        "rules" => { "identical_if_else_branches" => { "enabled" => false } }
      )
      expect(linter.lint_file(lint_fixture("identical_if_else_branches"))).to be_empty
    end

    it "auto-enables rules omitted from the config" do
      # Empty `rules:` block — every rule should still run.
      linter = described_class.from_config({ "rules" => {} })
      expect(linter.lint_file(lint_fixture("identical_if_else_branches")).length).to eq(2)
    end

    it "returns an empty hash when the config file is missing" do
      expect(described_class.load_config_file("/tmp/does-not-exist-#{Time.now.to_i}.yaml"))
        .to eq({})
    end
  end

  describe "encoding issues — canonical defaults" do
    it "flags each smart-punctuation byte/sequence when use_defaults is on" do
      Tempfile.create(["enc", ".sas"]) do |f|
        f.binmode
        f.write("label x = \xE2\x80\x98hello\xE2\x80\x99;\n")
        f.flush
        rule = SasLinter::Rules::EncodingIssues.new(use_defaults: true, autofix: false)
        findings = described_class.new(rules: [rule]).lint_file(f.path).select { |fd| fd.rule == :encoding_issues }
        expect(findings.length).to eq(2)
        expect(findings.map(&:line)).to all(eq(1))
      end
    end

    # Regression: codepoint() used to call String#encode("UTF-8") on the
    # ASCII-8BIT bytes from `pack("C*")`, which replaces every non-ASCII
    # byte with U+FFFD before the codepoint is read. Every multibyte
    # finding therefore reported `U+FFFD` regardless of what was matched.
    it "reports the actual codepoint of the matched UTF-8 sequence in the message" do
      Tempfile.create(["enc_msg", ".sas"]) do |f|
        f.binmode
        f.write("Hello\xE2\x80\x99world\xE2\x80\x93end\n") # U+2019 + U+2013
        f.flush
        rule = SasLinter::Rules::EncodingIssues.new(use_defaults: true, autofix: true)
        findings = described_class.new(rules: [rule]).lint_file(f.path).select { |fd| fd.rule == :encoding_issues }
        messages = findings.map(&:message)
        expect(messages).to include(a_string_including("U+2019"))
        expect(messages).to include(a_string_including("U+2013"))
        expect(messages).not_to include(a_string_including("U+FFFD"))
      end
    end

    it "rewrites smart punctuation to ASCII when use_defaults + autofix are on" do
      Tempfile.create(["enc_fix", ".sas"]) do |f|
        f.binmode
        f.write("label x = \xE2\x80\x98hello\xE2\x80\x99;\n")
        f.flush
        rule = SasLinter::Rules::EncodingIssues.new(use_defaults: true, autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq("label x = 'hello';\n")
      end
    end

    it "catches Windows-1252 single bytes that bypass UTF-8 transcoding" do
      Tempfile.create(["enc_w1252", ".sas"]) do |f|
        f.binmode
        # \x91 / \x92 are LEFT/RIGHT SINGLE QUOTATION MARK in Windows-1252;
        # standalone they're invalid UTF-8 so the byte-level table catches them.
        f.write("label x = \x91hello\x92;\n")
        f.flush
        rule = SasLinter::Rules::EncodingIssues.new(use_defaults: true, autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.binread(f.path)).to eq("label x = 'hello';\n")
      end
    end

    it "applies `replacements:` BEFORE the canonical defaults so user patterns can override default behavior" do
      Tempfile.create(["enc_user_wins", ".sas"]) do |f|
        f.binmode
        # Em-dash (\xE2\x80\x94). The canonical default would replace
        # it with "-"; the user map overrides to " // " on the SAME
        # bytes. Because user replacements run first, " // " wins.
        f.write("a \xE2\x80\x94 b\n")
        f.flush
        rule = SasLinter::Rules::EncodingIssues.new(
          use_defaults: true, autofix: true, replacements: { "—" => " // " }
        )
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq("a  //  b\n")
      end
    end

    # Regression: user replacements running AFTER defaults made cases
    # like `BJ\x85RKGREN` impossible to fix without disabling
    # `use_defaults` entirely — the canonical map consumed the
    # `\xE2\x80\xA6` (post-transcode ellipsis from a stray `\x85`)
    # bytes the user pattern needed to match.
    it "lets a user pattern target bytes the defaults would otherwise consume" do
      Tempfile.create(["enc_priority", ".sas"]) do |f|
        f.binmode
        # `\x85` byte, transcoded by read_source to UTF-8 ellipsis.
        f.write("M\x85LLER, ...; ellipsis on its own: \x85\n")
        f.flush
        rule = SasLinter::Rules::EncodingIssues.new(
          use_defaults: true, autofix: true,
          replacements: { "M…LLER" => "MÖLLER" }
        )
        described_class.new(rules: [rule]).lint_file(f.path)
        out = File.binread(f.path)
        expect(out).to include("MÖLLER".b)            # user pattern fired
        expect(out).to end_with("ellipsis on its own: ...\n".b) # default still cleaned up the rest
      end
    end

    it "leaves the rule a no-op when use_defaults is false and replacements is empty" do
      Tempfile.create(["enc_noop", ".sas"]) do |f|
        f.binmode
        f.write("label x = \xE2\x80\x98hello\xE2\x80\x99;\n")
        f.flush
        rule = SasLinter::Rules::EncodingIssues.new(autofix: true)
        before = File.binread(f.path)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.binread(f.path)).to eq(before)
      end
    end

    # Regression: a file with stray Windows-1252 bytes used to get
    # silently rewritten with the post-transcode bytes the moment
    # lint_file ran — even when no rule's autofix actually fired. The
    # bytes-only difference came from `read_source`'s Win-1252→UTF-8
    # transcode; the encoding-tag mismatch in the `modified != original`
    # test falsely registered as "the rule changed something."
    it "doesn't rewrite a file when no autofix rule actually changed any bytes" do
      Tempfile.create(["enc_no_match", ".sas"]) do |f|
        f.binmode
        # Raw \x85 byte — invalid UTF-8 standalone. read_source will
        # transcode it to \xE2\x80\xA6 in the in-memory source, but
        # the file on disk should keep the original byte intact when
        # no replacement matches.
        f.write("label x = \"BJ\x85RKGREN\";\n")
        f.flush
        before = File.binread(f.path)

        # User's replacement key (\xEF\xBF\xBD) doesn't match the raw
        # \x85 byte AND doesn't match the post-transcode \xE2\x80\xA6
        # either — so autofix is a true no-op and the file should be
        # left alone.
        rule = SasLinter::Rules::EncodingIssues.new(
          use_defaults: false, autofix: true,
          replacements: { "M\xEF\xBF\xBDLLER" => "MÖLLER" }
        )
        described_class.new(rules: [rule]).lint_file(f.path)

        expect(File.binread(f.path)).to eq(before)
      end
    end

    # Regression: `EncodingIssues#autofix` raised
    # `Encoding::CompatibilityError` when a multi-byte UTF-8 key in
    # `replacements:` matched against the BINARY-encoded source
    # `apply_canonical_fix` returns. The UTF-8 (`from`) string and the
    # binary source were encoding-incompatible inside `String#gsub`.
    it "applies a multi-byte UTF-8 `replacements:` key on top of the canonical defaults without raising" do
      Tempfile.create(["enc_user_utf8", ".sas"]) do |f|
        f.binmode
        # U+2030 PER MILLE SIGN (\xE2\x80\xB0) — not in the canonical
        # UTF8_REPLACEMENTS table, so it survives `step1` and the
        # user's `replacements:` map is the only thing that can rewrite
        # it. With `use_defaults: true`, `step1` is BINARY and the
        # gsub-encoding mismatch surfaces.
        f.write("value: 5\xE2\x80\xB0\n")
        f.flush

        rule = SasLinter::Rules::EncodingIssues.new(
          use_defaults: true, autofix: true, replacements: { "‰" => " per mille" }
        )

        expect do
          described_class.new(rules: [rule]).lint_file(f.path)
        end.not_to raise_error
        expect(File.binread(f.path)).to eq("value: 5 per mille\n")
      end
    end
  end

  describe "source headers" do
    it "flags broken header lines whose prose leaks past an inline `;` and rewrites them" do
      Tempfile.create(["hdr_fix", ".sas"]) do |f|
        # Header line with an inline `;` mid-prose and no trailing `**;` —
        # the lexer closes the comment at the inline `;` and leaks the
        # second-reviewer name as DEFAULT-channel IDENTIFIERs.
        f.write(File.read(lint_fixture("source_headers")))
        f.flush
        rule = SasLinter::Rules::SourceHeaders.new(autofix: true)
        findings = described_class.new(rules: [rule]).lint_file(f.path).select { |fd| fd.rule == :source_headers }
        expect(findings).not_to be_empty
        rewritten = File.read(f.path)
        expect(rewritten).to include("**  CHECKED BY:       First Reviewer; Second Reviewer                                  **;")
      end
    end
  end

  describe "line endings" do
    it "flags `\\r\\r\\n` (double CR before LF) — Word/Outlook copy-paste damage" do
      Tempfile.create(["dblcr", ".sas"]) do |f|
        f.binmode
        f.write("data one;\r\r\nrun;\r\r\n")
        f.flush
        rule = SasLinter::Rules::LineEndings.new(autofix: false)
        findings = described_class.new(rules: [rule]).lint_file(f.path).select { |fd| fd.rule == :line_endings }
        expect(findings.length).to eq(2)
        expect(findings.map(&:line)).to eq([1, 2])
        expect(findings.first.message).to include("double CR")
      end
    end

    it "flags lone `\\r` (CR-only, old-Mac) line endings" do
      Tempfile.create(["cronly", ".sas"]) do |f|
        f.binmode
        f.write("data one;\rrun;\rstop;\r")
        f.flush
        rule = SasLinter::Rules::LineEndings.new(autofix: false)
        findings = described_class.new(rules: [rule]).lint_file(f.path).select { |fd| fd.rule == :line_endings }
        expect(findings.length).to eq(3)
        expect(findings.first.message).to include("lone CR")
      end
    end

    it "produces no findings on a clean LF file" do
      Tempfile.create(["lf", ".sas"]) do |f|
        f.write("data one;\nrun;\n")
        f.flush
        rule = SasLinter::Rules::LineEndings.new(autofix: false)
        expect(described_class.new(rules: [rule]).lint_file(f.path)).to be_empty
      end
    end

    it "produces no findings on a clean CRLF file" do
      Tempfile.create(["crlf", ".sas"]) do |f|
        f.binmode
        f.write("data one;\r\nrun;\r\n")
        f.flush
        rule = SasLinter::Rules::LineEndings.new(autofix: false)
        expect(described_class.new(rules: [rule]).lint_file(f.path)).to be_empty
      end
    end

    it "autofix collapses `\\r\\r\\n` → `\\r\\n` and preserves CRLF dominance" do
      Tempfile.create(["dblcr_fix", ".sas"]) do |f|
        f.binmode
        f.write("data one;\r\r\nrun;\r\r\n")
        f.flush
        rule = SasLinter::Rules::LineEndings.new(autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.binread(f.path)).to eq("data one;\r\nrun;\r\n")
      end
    end

    it "autofix on a CR-only file converts every CR to LF" do
      Tempfile.create(["cronly_fix", ".sas"]) do |f|
        f.binmode
        f.write("data one;\rrun;\rstop;\r")
        f.flush
        rule = SasLinter::Rules::LineEndings.new(autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.binread(f.path)).to eq("data one;\nrun;\nstop;\n")
      end
    end

    it "autofix on a mostly-CRLF file maps stray lone CRs to CRLF too" do
      Tempfile.create(["mixed_fix", ".sas"]) do |f|
        f.binmode
        f.write("data one;\r\nrun;\rstop;\r\n")
        f.flush
        rule = SasLinter::Rules::LineEndings.new(autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.binread(f.path)).to eq("data one;\r\nrun;\r\nstop;\r\n")
      end
    end
  end

  describe "inconsistent variable case" do
    let(:findings) do
      described_class.new(rules: [:inconsistent_variable_case])
                     .lint_file(lint_fixture("inconsistent_variable_case"))
    end

    it "flags the minority spelling and tells the user the canonical form to use" do
      expect(findings.length).to eq(1)
      expect(findings[0].rule).to eq(:inconsistent_variable_case)
      expect(findings[0].line).to eq(7)
      expect(findings[0].column).to eq(23)
      expect(findings[0].message).to include("`MyFlag`")
      expect(findings[0].message).to include("`myFlag`")
    end

    it "does not flag the format-name occurrence in `proc format value <name>` " \
       "or the format reference `<name>.` — those legitimately share a name " \
       "with the variable" do
      # The fixture has `value myFlag` and `format ... myFlag.` in addition
      # to the variable uses; if those got bucketed with the variables we'd
      # see more than one finding.
      expect(findings.map(&:line)).to eq([7])
    end

    it "produces no findings when every use shares one casing" do
      clean = described_class.new(rules: [:inconsistent_variable_case])
                             .lint_file(clean_fixture("inconsistent_variable_case"))
      expect(clean).to be_empty
    end

    it "autofix rewrites every minority spelling to the most-common form" do
      Tempfile.create(["ivc_fix", ".sas"]) do |f|
        f.write(File.read(lint_fixture("inconsistent_variable_case")))
        f.flush
        rule = SasLinter::Rules::InconsistentVariableCase.new(autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq(File.read(clean_fixture("inconsistent_variable_case")))
      end
    end

    it "leaves the file untouched when autofix is off" do
      Tempfile.create(["ivc_dry", ".sas"]) do |f|
        f.write(File.read(lint_fixture("inconsistent_variable_case")))
        f.flush
        before = File.read(f.path)
        described_class.new(rules: [:inconsistent_variable_case]).lint_file(f.path)
        expect(File.read(f.path)).to eq(before)
      end
    end

    it "autofix stays correct when the source arrives as ASCII-8BIT " \
       "(e.g. after EncodingIssues#autofix) with multi-byte chars upstream" do
      # Regression: the IVC autofix used to slice the source with
      # character-based `String#[]=` while the lexer reports character
      # offsets. That's fine when the source is UTF-8 — but
      # EncodingIssues#autofix returns ASCII-8BIT, on which `[]=` is
      # byte-indexed. Any multi-byte UTF-8 sequence earlier in the
      # file then shifted every replacement by the byte/char gap and
      # corrupted the output (the smart-punctuation glyphs in the
      # fixture comment are enough to trigger it).
      Tempfile.create(["ivc_chained", ".sas"]) do |f|
        f.binmode
        f.write(File.binread(lint_fixture("inconsistent_variable_case_after_binary_autofix")))
        f.flush
        enc = SasLinter::Rules::EncodingIssues.new(use_defaults: true, autofix: true)
        ivc = SasLinter::Rules::InconsistentVariableCase.new(autofix: true)
        described_class.new(rules: [enc, ivc]).lint_file(f.path)
        expect(File.binread(f.path))
          .to eq(File.binread(clean_fixture("inconsistent_variable_case_after_binary_autofix")))
      end
    end

    it "picks the most-common spelling as canonical, not the first-seen one" do
      # Two `LOWER` uses, three `lower` uses — `lower` wins on count even
      # though `LOWER` appears first.
      Tempfile.create(["ivc_majority", ".sas"]) do |f|
        f.write("data x;\n  LOWER = 1; LOWER = 2;\n  lower = 3; lower = 4; lower = 5;\nrun;\n")
        f.flush
        rule = SasLinter::Rules::InconsistentVariableCase.new(autofix: true)
        described_class.new(rules: [rule]).lint_file(f.path)
        expect(File.read(f.path)).to eq(
          "data x;\n  lower = 1; lower = 2;\n  lower = 3; lower = 4; lower = 5;\nrun;\n"
        )
      end
    end
  end

  describe "format for unknown variable" do
    let(:findings) do
      described_class.new(rules: [:format_for_unknown_variable])
                     .lint_file(lint_fixture("format_for_unknown_variable"))
    end

    it "flags an `attrib var format=fmt.;` whose variable is not referenced anywhere else" do
      expect(findings.length).to eq(1)
      expect(findings[0].rule).to eq(:format_for_unknown_variable)
      expect(findings[0].line).to eq(10)
      expect(findings[0].column).to eq(11)
      expect(findings[0].message).to include("`totalscore`")
      expect(findings[0].message).to include("attrib")
      expect(findings[0].message).to include("not referenced anywhere else")
    end

    it "produces no findings when every formatted variable is referenced elsewhere" do
      clean = described_class.new(rules: [:format_for_unknown_variable])
                             .lint_file(clean_fixture("format_for_unknown_variable"))
      expect(clean).to be_empty
    end

    it "flags a standalone `format <var> <fmt>.;` when the var is unknown" do
      out = described_class.new(rules: [:format_for_unknown_variable])
                           .lint_file(File.join(lints_path, "format_for_unknown_variable", "standalone_format.sas"))
      expect(out.length).to eq(1)
      expect(out[0].line).to eq(3)
      expect(out[0].message).to include("`totalscore`")
      expect(out[0].message).to include("format")
    end

    it "flags every unknown variable in a multi-target format statement" do
      out = described_class.new(rules: [:format_for_unknown_variable])
                           .lint_file(File.join(lints_path, "format_for_unknown_variable", "multi_target.sas"))
      # message format: "`format` assigns a format to `<var>` ..."
      flagged = out.map { |x| x.message[/to `(\w+)`/, 1] }
      expect(flagged).to contain_exactly("phantom1", "phantom2")
    end

    it "skips the file entirely when a `set` statement pulls in unknown columns" do
      path = File.join(lints_path, "format_for_unknown_variable", "external_input_skipped.sas")
      out = described_class.new(rules: [:format_for_unknown_variable]).lint_file(path)
      expect(out).to be_empty
    end

    it "does not count `proc format` `value <name>` as a variable use" do
      # `value flagx` defines a format named flagx — `flagx` is not a
      # variable reference, so a lone `attrib v format=flagx.;` should
      # still flag `v`, not be silenced by the format definition's name.
      out = described_class.new(rules: [:format_for_unknown_variable])
                           .lint_file(File.join(lints_path, "format_for_unknown_variable", "proc_format_value.sas"))
      expect(out.length).to eq(1)
      expect(out[0].message).to include("`v`")
    end

    it "does not flag a variable that is only declared in `keep` / `retain`" do
      # `keep` and `retain` name variables that *are* used elsewhere in
      # real code; they shouldn't be the sole evidence of use, but for
      # this rule they're already excluded from the use index — what
      # matters is that adding them doesn't produce a finding for the
      # var that *is* assigned.
      out = described_class.new(rules: [:format_for_unknown_variable])
                           .lint_file(File.join(lints_path, "format_for_unknown_variable", "keep_retain.sas"))
      expect(out).to be_empty
    end
  end

  describe "format_file" do
    it "applies formatter transformations regardless of rule autofix settings" do
      Tempfile.create(["fmt", ".sas"]) do |f|
        f.write("data foo;\nx=1;\nrun;\n")
        f.flush
        formatter = SasLinter::Formatter.new(operator_spacing: true)
        linter = described_class.new  # all rules with autofix: false (default)
        linter.format_file(f.path, formatter: formatter)
        expect(File.read(f.path)).to eq("data foo;\nx = 1;\nrun;\n")
      end
    end

    it "does not apply a rule's autofix when autofix: false" do
      Tempfile.create(["fmt_no_autofix", ".sas"]) do |f|
        f.write("data foo;   \nrun;\n")
        f.flush
        formatter = SasLinter::Formatter.new
        rule = SasLinter::Rules::TrailingWhitespace.new(autofix: false)
        described_class.new(rules: [rule]).format_file(f.path, formatter: formatter)
        expect(File.read(f.path)).to eq("data foo;   \nrun;\n")
      end
    end

    it "applies a rule's autofix when autofix: true" do
      Tempfile.create(["fmt_autofix", ".sas"]) do |f|
        f.write("data foo;   \nrun;\n")
        f.flush
        formatter = SasLinter::Formatter.new
        rule = SasLinter::Rules::TrailingWhitespace.new(autofix: true)
        described_class.new(rules: [rule]).format_file(f.path, formatter: formatter)
        expect(File.read(f.path)).to eq("data foo;\nrun;\n")
      end
    end

    it "runs formatter and opted-in rule autofixes together" do
      Tempfile.create(["fmt_both", ".sas"]) do |f|
        f.write("data foo;   \nx=1;\nrun;\n")
        f.flush
        formatter = SasLinter::Formatter.new(operator_spacing: true)
        rule = SasLinter::Rules::TrailingWhitespace.new(autofix: true)
        described_class.new(rules: [rule]).format_file(f.path, formatter: formatter)
        expect(File.read(f.path)).to eq("data foo;\nx = 1;\nrun;\n")
      end
    end
  end

  describe "Finding#to_s" do
    it "formats as path:line:column: [rule] message" do
      f = SasLinter::Finding.new(
        path: "x.sas", line: 4, column: 23,
        rule: :unreachable_inner_branch_value,
        message: "value 7 for STAGE_VAR is excluded ...",
        severity: :warning
      )
      expect(f.to_s).to eq(
        "x.sas:4:23: [unreachable_inner_branch_value] value 7 for STAGE_VAR is excluded ..."
      )
    end
  end
end
