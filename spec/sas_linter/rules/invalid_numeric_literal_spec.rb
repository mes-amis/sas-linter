# frozen_string_literal: true

require "spec_helper"

RSpec.describe SasLinter::Rules::InvalidNumericLiteral do
  let(:fixture_dir) { File.expand_path("../../fixtures/lints/invalid_numeric_literal", __dir__) }
  let(:lint_path) { File.join(fixture_dir, "lint.sas") }
  let(:clean_path) { File.join(fixture_dir, "clean.sas") }
  let(:linter) { SasLinter.new(rules: [:invalid_numeric_literal]) }

  it "registers under :invalid_numeric_literal" do
    expect(SasLinter::Rule.fetch(:invalid_numeric_literal)).to eq(described_class)
  end

  it "flags `1f`-style suffixes the lexer munches into INTEGER_LITERAL but SAS rejects" do
    findings = linter.lint_file(lint_path)
    expect(findings.map(&:rule).uniq).to eq([:invalid_numeric_literal])
    expect(findings.length).to eq(3)

    line1 = findings.find { |f| f.line == 1 }
    expect(line1.column).to eq(32)
    expect(line1.message).to include("`1f`")
    expect(line1.message).to include("not a valid SAS numeric literal")

    line2 = findings.find { |f| f.line == 2 }
    expect(line2.message).to include("`1F`")

    line3 = findings.find { |f| f.line == 3 }
    expect(line3.message).to include("`1d2`")
  end

  it "does not flag plain decimals or valid hex literals like `0FFx`" do
    expect(linter.lint_file(clean_path)).to be_empty
  end
end
