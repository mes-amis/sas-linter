# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe SasLinter::Rules::VariableValueOutOfKnownRange do
  let(:fixture_dir) { File.expand_path("../../fixtures/lints/variable_value_out_of_known_range", __dir__) }
  let(:csv_path) { File.join(fixture_dir, "variables.csv") }
  let(:lint_path) { File.join(fixture_dir, "lint.sas") }
  let(:clean_path) { File.join(fixture_dir, "clean.sas") }

  # The fixture CSV uses `;` as its column separator so values like `0-3,8`
  # don't get split mid-cell.
  let(:rule) { described_class.new(csv_paths: [csv_path], delimiter: ";") }
  let(:linter) { SasLinter.new(rules: [rule]) }

  it "is a no-op when csv_paths is empty" do
    rule = described_class.new(csv_paths: [])
    findings = SasLinter.new(rules: [rule]).lint_file(lint_path)
    expect(findings).to be_empty
  end

  it "flags `if VAR in (...)` literals outside the documented acceptable values" do
    findings = linter.lint_file(lint_path)
    expect(findings.length).to eq(4)
    expect(findings.map(&:rule).uniq).to eq([:variable_value_out_of_known_range])

    expect(findings[0].line).to eq(1)
    expect(findings[0].message).to include("value 99 for V1")
    expect(findings[0].message).to include("0..2")

    expect(findings[1].line).to eq(2)
    expect(findings[1].message).to include("value 99 for SCORE")
    expect(findings[1].message).to include("0..5")

    expect(findings[2].line).to eq(3)
    expect(findings[2].message).to include("value 7 for RANK")
    expect(findings[2].message).to include("0..6")

    expect(findings[3].line).to eq(4)
    expect(findings[3].message).to include("value 9 for V4")
    expect(findings[3].message).to include("{0, 1, 2, 3, 8}")
  end

  it "ignores assignments, missing sentinels, and unknown identifiers" do
    expect(linter.lint_file(clean_path)).to be_empty
  end

  describe "name matching" do
    it "is case-insensitive by default" do
      Tempfile.create(["lc", ".sas"]) do |f|
        f.write("if v1 = 99 then x = 1; run;\n")
        f.flush
        findings = linter.lint_file(f.path)
        expect(findings.length).to eq(1)
        expect(findings[0].message).to include("for v1")
      end
    end

    it "treats names as exact when `name_match: :exact`" do
      exact_rule = described_class.new(csv_paths: [csv_path], delimiter: ";", name_match: :exact)
      Tempfile.create(["mixed", ".sas"]) do |f|
        f.write("if v1 = 99 then x = 1; run;\n")
        f.flush
        findings = SasLinter.new(rules: [exact_rule]).lint_file(f.path)
        # The CSV stores "V1" (uppercase). With exact matching, lowercase
        # `v1` is not in the catalog, so nothing fires.
        expect(findings).to be_empty
      end
    end

    it "rejects an unknown name_match symbol at construction time" do
      expect do
        described_class.new(csv_paths: [csv_path], name_match: :prefix)
      end.to raise_error(ArgumentError, /name_match/)
    end
  end

  describe "configurable delimiter" do
    it "defaults to `,` so a standard CSV works without configuration" do
      Tempfile.create(["std", ".csv"]) do |csv|
        csv.write("Variable,Acceptable Values\nX,0-2\n")
        csv.flush
        rule = described_class.new(csv_paths: [csv.path]) # default delimiter: ","
        Tempfile.create(["src", ".sas"]) do |f|
          f.write("if X = 9 then y = 1; run;\n")
          f.flush
          findings = SasLinter.new(rules: [rule]).lint_file(f.path)
          expect(findings.length).to eq(1)
        end
      end
    end

    it "honors `delimiter: ';'` so values with commas (`0-3,8`) parse correctly" do
      # Use case: the values column contains commas
      # so the file uses `;` as its column separator.
      findings = linter.lint_file(lint_path)
      adl = findings.find { |f| f.message.include?("V4") }
      expect(adl).not_to be_nil
      expect(adl.message).to include("{0, 1, 2, 3, 8}")
    end

    it "supports `delimiter: \"\\t\"` (tab-separated)" do
      Tempfile.create(["tsv", ".tsv"]) do |csv|
        csv.write("Variable\tAcceptable Values\nX\t0-2\n")
        csv.flush
        rule = described_class.new(csv_paths: [csv.path], delimiter: "\t")
        Tempfile.create(["src", ".sas"]) do |f|
          f.write("if X = 5 then y = 1; run;\n")
          f.flush
          findings = SasLinter.new(rules: [rule]).lint_file(f.path)
          expect(findings.length).to eq(1)
          expect(findings[0].message).to include("for X")
        end
      end
    end
  end

  describe "configurable column names" do
    it "honors `name_column:` and `values_column:` overrides" do
      Tempfile.create(["custom", ".csv"]) do |csv|
        csv.write("Identifier,Range\nFOO,0-2\n")
        csv.flush
        rule = described_class.new(
          csv_paths: [csv.path],
          name_column: "Identifier",
          values_column: "Range"
        )
        Tempfile.create(["src", ".sas"]) do |f|
          f.write("if FOO = 9 then x = 1; run;\n")
          f.flush
          findings = SasLinter.new(rules: [rule]).lint_file(f.path)
          expect(findings.length).to eq(1)
          expect(findings[0].message).to include("value 9 for FOO")
        end
      end
    end

    it "is silently empty when the configured column names don't match the CSV headers" do
      Tempfile.create(["bad_cols", ".csv"]) do |csv|
        csv.write("Foo,Bar\nFOO,0-2\n")
        csv.flush
        rule = described_class.new(
          csv_paths: [csv.path],
          name_column: "Variable",
          values_column: "Acceptable Values"
        )
        Tempfile.create(["src", ".sas"]) do |f|
          f.write("if FOO = 9 then x = 1; run;\n")
          f.flush
          expect(SasLinter.new(rules: [rule]).lint_file(f.path)).to be_empty
        end
      end
    end
  end

  describe ".from_config" do
    it "expands csv_paths and forwards every option" do
      config = {
        "csv_paths" => [csv_path],
        "name_column" => "Variable",
        "values_column" => "Acceptable Values",
        "delimiter" => ";",
        "name_match" => "case_insensitive"
      }
      rule = described_class.from_config(config)
      expect(SasLinter.new(rules: [rule]).lint_file(lint_path).length).to eq(4)
    end

    it "defaults to a no-op when csv_paths is omitted" do
      rule = described_class.from_config({})
      expect(SasLinter.new(rules: [rule]).lint_file(lint_path)).to be_empty
    end
  end

  describe "value-string parsing" do
    # Use `;` as the column separator so we can put commas inside values
    # (`0-3,8`, `1,2,3`) without quoting.
    def find_with_csv(rows, source:)
      Tempfile.create(["c", ".csv"]) do |csv|
        csv.write("Variable;Acceptable Values\n")
        rows.each { |name, vals| csv.write("#{name};#{vals}\n") }
        csv.flush
        Tempfile.create(["s", ".sas"]) do |f|
          f.write(source)
          f.flush
          rule = described_class.new(csv_paths: [csv.path], delimiter: ";")
          return SasLinter.new(rules: [rule]).lint_file(f.path)
        end
      end
    end

    it "parses simple integer ranges (`0-5`)" do
      findings = find_with_csv([["X", "0-5"]], source: "if X = 9 then y = 1; run;\n")
      expect(findings.length).to eq(1)
      expect(findings[0].message).to include("0..5")
    end

    it "parses comma-separated sets (`1,2,3`)" do
      findings = find_with_csv([["X", "1,2,3"]], source: "if X = 4 then y = 1; run;\n")
      expect(findings.length).to eq(1)
      expect(findings[0].message).to include("{1, 2, 3}")
    end

    it "parses a range plus extras (`0-3, 8`)" do
      findings = find_with_csv([["X", "0-3, 8"]], source: "if X in (0,1,2,3,8,9) then y = 1; run;\n")
      expect(findings.length).to eq(1)
      expect(findings[0].message).to include("value 9")
    end

    it "parses a range with parenthesized extras (`0-90 (99)`)" do
      findings = find_with_csv([["X", "0-90 (99)"]], source: "if X = 100 then y = 1; run;\n")
      expect(findings.length).to eq(1)
      expect(findings[0].message).to include("value 100")
    end

    it "skips rows with a free-text or date pattern in the values column" do
      findings = find_with_csv(
        [["X", "any positive integer"], ["Y", "MM/DD/YYYY"]],
        source: "if X = 99 then y = 1;\nif Y = 99 then y = 2; run;\n"
      )
      expect(findings).to be_empty
    end
  end
end
