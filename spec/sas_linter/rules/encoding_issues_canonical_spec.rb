# frozen_string_literal: true

require "spec_helper"
require "sas_linter"

# Byte-level coverage for the canonical-defaults autofix of the
# `encoding_issues` rule. The rule must rewrite Win-1252 mojibake
# without ever mangling bytes that sit inside a valid UTF-8 sequence
# (e.g. the `\x96` continuation byte of `Ö` in a name like `MÜLLER`).
RSpec.describe SasLinter::Rules::EncodingIssues do
  let(:fixture_dir) { File.join(__dir__, "..", "..", "fixtures", "encoding_issues_canonical") }
  let(:rule) { described_class.new }

  def load_fixture(name)
    File.binread(File.join(fixture_dir, "#{name}.sas"))
  end

  # The byte-level pure function the rule's autofix delegates to when
  # `use_defaults: true`. Tests target this directly so failures point
  # at the substitution table rather than the surrounding rule wiring.
  def fix(src)
    rule.apply_canonical_fix(src)
  end

  describe "#apply_canonical_fix" do
    context "when the source is already pure ASCII" do
      it "returns the source unchanged" do
        src = load_fixture("clean_ascii")

        expect(fix(src)).to eq(src)
      end
    end

    context "when the source has Windows-1252 single smart quotes" do
      it "replaces 0x91 / 0x92 with ASCII `'`" do
        src = +"label x = \x91foo\x92;\n"

        out = fix(src.b)

        expect(out).to eq("label x = 'foo';\n")
      end
    end

    context "when the source has Windows-1252 double smart quotes" do
      it "replaces 0x93 / 0x94 with ASCII `\"`" do
        src = +"label x = \x93Hello World\x94;\n"

        out = fix(src.b)

        expect(out).to eq(%(label x = "Hello World";\n))
      end
    end

    context "when the source has Windows-1252 en/em dashes" do
      it "replaces 0x96 / 0x97 with ASCII `-`" do
        src = +"** range 0\x963 \x97 typical\n"

        out = fix(src.b)

        expect(out).to eq("** range 0-3 - typical\n")
      end
    end

    context "when the source has a Windows-1252 ellipsis byte (0x85)" do
      it "leaves it alone — in real-world SAS sources 0x85 is overwhelmingly a corrupted Latin-1 letter (e.g. an `\\x85` standing in for `Ö` inside a surname), not a real ellipsis" do
        src = "**  AUTHOR \x85, COAUTHOR \x85,\n".b

        out = fix(src)

        expect(out).to eq(src)
      end
    end

    context "when the source has Windows-1252 non-breaking spaces" do
      it "replaces 0xA0 with ASCII space" do
        src = +"** spaced\xA0word\n"

        out = fix(src.b)

        expect(out).to eq("** spaced word\n")
      end
    end

    context "when the source has UTF-8 smart quotes already encoded as multibyte" do
      it "decodes U+2018 / U+2019 to ASCII `'`" do
        src = "label x = ‘foo’;\n".b

        out = fix(src)

        expect(out).to eq("label x = 'foo';\n")
      end

      it "decodes U+201C / U+201D to ASCII `\"`" do
        src = "label x = “Hi”;\n".b

        out = fix(src)

        expect(out).to eq(%(label x = "Hi";\n))
      end

      it "decodes U+2013 / U+2014 to ASCII `-`" do
        src = "** range 0–3 — typical\n".b

        out = fix(src)

        expect(out).to eq("** range 0-3 - typical\n")
      end

      it "decodes U+2026 (ellipsis) to ASCII `...`" do
        src = "** continued…\n".b

        out = fix(src)

        expect(out).to eq("** continued...\n")
      end

      it "decodes U+2002 EN SPACE / U+2003 EM SPACE / U+2009 THIN SPACE to ASCII space" do
        # A stray U+2003 (EM SPACE, UTF-8 \xE2\x80\x83) at the start of a
        # statement makes SAS reject the line with `ERROR 217-322: Invalid
        # statement due to first character being unprintable`. Cover the
        # whole `\xE2\x80\x80`-`\xE2\x80\x8A` typographic-space range plus
        # the related zero-width and line-separator chars.
        src = "a\xE2\x80\x82b\xE2\x80\x83c\xE2\x80\x89d\n".b

        out = fix(src)

        expect(out).to eq("a b c d\n")
      end
    end

    context "when the source has Mac-Roman-misread-as-Win-1252 mojibake (UTF-8 form)" do
      # When a Mac-Roman-authored file gets transcoded as Win-1252 → UTF-8
      # by `SasLinter#read_source`, the Mac Roman 0xD0–0xD5 smart-punctuation
      # block surfaces as Latin-1 letters Ð / Ò / Ó / Ô / Õ.
      it "rewrites Ð to a hyphen" do
        out = fix("FOO \xC3\x90 BAR".b)
        expect(out).to eq("FOO - BAR".b)
      end

      it "rewrites Ò / Ó to ASCII straight double quotes" do
        out = fix("user said \xC3\x92hello\xC3\x93 today".b)
        expect(out).to eq('user said "hello" today'.b)
      end

      it "rewrites Ô / Õ to ASCII straight single quotes" do
        out = fix("\xC3\x94and\xC3\x95".b)
        expect(out).to eq("'and'".b)
      end

      it "leaves Ñ (U+00D1) alone — too much legitimate Spanish-name traffic to auto-replace" do
        out = fix("se\xC3\x91or".b)
        expect(out).to eq("se\xC3\x91or".b)
      end
    end

    context "when the source mixes Windows-1252 mangling and clean text" do
      it "only replaces the mangled bytes and leaves clean text alone" do
        src = +"plain text\nlabel x = \x91foo\x92;\nmore plain text\n"

        out = fix(src.b)

        expect(out).to eq("plain text\nlabel x = 'foo';\nmore plain text\n")
      end
    end

    context "when the result is fed back through .fix" do
      it "is idempotent — second pass changes nothing" do
        src = +"label x = \x91foo\x92;\n".b

        first = fix(src)
        second = fix(first)

        expect(second).to eq(first)
      end
    end

    context "when a Windows-1252 punctuation byte is the *continuation* byte of a valid UTF-8 sequence" do
      it "leaves it alone — it's part of a valid character, not standalone smart punctuation" do
        # `MÜLLER` in UTF-8 is `M\xC3\x9CLLER`. Substitute another name with
        # the `\x96` continuation byte: U+00D6 (Ö) is `\xC3\x96`. The `\x96`
        # is BOTH a standalone Windows-1252 en-dash AND the continuation
        # byte of `Ö`. The fixer must distinguish the two and never break
        # a real character.
        src = "M\xC3\x96LLER".b

        out = fix(src)

        expect(out).to eq("M\xC3\x96LLER".b)
      end

      it "still replaces the same byte when it really is standalone" do
        # No UTF-8 lead byte before it — must be replaced.
        src = "0\x963".b

        out = fix(src)

        expect(out).to eq("0-3")
      end

      it "leaves continuation bytes of 3-byte UTF-8 sequences alone" do
        # `\xE2\x80\x99` is U+2019 (right single quote) — already covered by
        # UTF-8 substitution. But `\xE2\x80\xAC` (U+202C, pop directional
        # formatting — NOT in our UTF-8 map) has 0x80 and 0xAC continuation
        # bytes; 0x80 must NOT be touched even though it's "in" the
        # Windows-1252 0x80-0x9F range nominally.
        src = "x\xE2\x80\xACy".b

        out = fix(src)

        expect(out).to eq("x\xE2\x80\xACy".b)
      end
    end

    context "when the source has a stray Windows-1252 byte that's not in our known map" do
      it "leaves it alone (we don't guess at unknown encodings)" do
        # 0x80 is a Windows-1252 Euro sign — not in our ASCII map. Leave
        # alone rather than corrupting downstream comparison.
        src = +"junk \x80 byte\n".b

        out = fix(src)

        expect(out).to eq(src)
      end
    end
  end
end
