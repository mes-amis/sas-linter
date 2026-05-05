# frozen_string_literal: true

require "spec_helper"

RSpec.describe SasLinter::Formatter do
  FIXTURE_DIR = File.join(__dir__, "..", "fixtures", "format")

  def fixture(name)
    File.read(File.join(FIXTURE_DIR, name))
  end

  # --- Config parsing ---

  describe ".from_config" do
    it "is a no-op when the format: key is absent" do
      fmt = described_class.from_config({})
      src = "data foo; x=1; run;"
      expect(fmt.format(src)).to equal(src)
    end

    it "reads keywords, operator_spacing, and indent_width" do
      fmt = described_class.from_config(
        "format" => { "keywords" => "upper", "operator_spacing" => true, "indent_width" => 4 }
      )
      expect(fmt.instance_variable_get(:@keywords)).to eq(:upper)
      expect(fmt.instance_variable_get(:@operator_spacing)).to be true
      expect(fmt.instance_variable_get(:@indent_width)).to eq(4)
    end

    it "raises on an unrecognised keywords value" do
      expect { described_class.from_config("format" => { "keywords" => "mixed" }) }
        .to raise_error(ArgumentError, /keywords/)
    end

    it "treats indent_width: 0 as disabled" do
      fmt = described_class.from_config("format" => { "indent_width" => 0 })
      expect(fmt.instance_variable_get(:@indent_width)).to be_nil
    end
  end

  # --- Keyword casing ---

  describe "keyword casing" do
    it "uppercases SAS keywords" do
      fmt = described_class.new(keywords: :upper)
      expect(fmt.format("data foo; set bar; if x=1 then output; run;"))
        .to eq("DATA foo; SET bar; IF x=1 THEN OUTPUT; RUN;")
    end

    it "lowercases SAS keywords" do
      fmt = described_class.new(keywords: :lower)
      expect(fmt.format("DATA FOO; SET BAR; RUN;"))
        .to eq("data FOO; set BAR; run;")
    end

    it "does not alter string literal contents" do
      fmt = described_class.new(keywords: :upper)
      # `label` is a keyword → uppercased; words inside the string stay untouched
      expect(fmt.format("label x = 'run data proc';"))
        .to eq("LABEL x = 'run data proc';")
    end
  end

  # --- Operator spacing ---

  describe "operator spacing" do
    let(:fmt) { described_class.new(operator_spacing: true) }

    it "matches the operator_spacing fixture" do
      expect(fmt.format(fixture("operator_spacing.sas")))
        .to eq(fixture("operator_spacing.formatted.sas"))
    end

    it "matches the unary_operators fixture" do
      expect(fmt.format(fixture("unary_operators.sas")))
        .to eq(fixture("unary_operators.formatted.sas"))
    end

    it "is idempotent" do
      once = fmt.format(fixture("operator_spacing.sas"))
      expect(fmt.format(once)).to eq(once)
    end

    it "does not normalize whitespace that spans a line boundary" do
      src = "if a > 0\n  and b < 10 then x = 1;\n"
      expect(fmt.format(src)).to eq(src)
    end

    it "preserves string literal contents" do
      src = "label x = 'hello=world';\n"
      expect(fmt.format(src)).to eq(src)
    end

    it "preserves CRLF line endings" do
      src = "x=1;\r\ny=2;\r\n"
      expect(fmt.format(src)).to eq("x = 1;\r\ny = 2;\r\n")
    end
  end

  # --- Indentation ---

  describe "indentation" do
    let(:fmt) { described_class.new(indent_width: 2) }

    it "matches the indentation fixture" do
      expect(fmt.format(fixture("indentation.sas")))
        .to eq(fixture("indentation.formatted.sas"))
    end

    it "is idempotent" do
      once = fmt.format(fixture("indentation.sas"))
      expect(fmt.format(once)).to eq(once)
    end

    it "preserves blank lines between steps" do
      once = fmt.format(fixture("indentation.sas"))
      expect(once).to include("run;\n\nproc sort")
    end
  end

  # --- Combined ---

  describe "combined keyword casing + operator spacing + indentation" do
    let(:fmt) { described_class.new(keywords: :upper, operator_spacing: true, indent_width: 2) }

    it "applies all three transformations together" do
      src = "data foo;\nx=1;\nif x>0 then do;\ny=x+1;\nend;\nrun;\n"
      expect(fmt.format(src))
        .to eq("DATA foo;\n  x = 1;\n  IF x > 0 THEN DO;\n    y = x + 1;\n  END;\nRUN;\n")
    end

    it "is idempotent" do
      src = "data foo;\nx=1;\nif x>0 then do;\ny=x+1;\nend;\nrun;\n"
      once = fmt.format(src)
      expect(fmt.format(once)).to eq(once)
    end
  end

  # --- No-op ---

  describe "no-op (all defaults)" do
    it "returns the exact same object when nothing is configured" do
      src = "data foo;\nx=1;\nrun;\n"
      fmt = described_class.new
      expect(fmt.format(src)).to equal(src)
    end
  end
end
