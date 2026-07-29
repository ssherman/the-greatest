class WidenDescriptionContentNotBlankConstraint < ActiveRecord::Migration[8.1]
  # Single-argument btrim() trims ASCII spaces only, so "\t\n" satisfied the original
  # constraint while being .blank? in Ruby -- D15's known gap. The legacy books data that
  # increment b2 reads contains one whitespace-only ai_generated_description, so the gap is
  # real, not theoretical: a build_rows that tested truthiness instead of .presence would
  # land it and still pass the row-count verification. Widened here, before the 186,634-row
  # backfill, while the table holds only 11,382 rows and validation is instant.
  def up
    remove_check_constraint :descriptions, name: "descriptions_content_not_blank"
    add_check_constraint :descriptions,
      "length(btrim(content, E' \\t\\n\\r\\f\\v')) > 0",
      name: "descriptions_content_not_blank"
  end

  def down
    remove_check_constraint :descriptions, name: "descriptions_content_not_blank"
    add_check_constraint :descriptions,
      "length(btrim(content)) > 0",
      name: "descriptions_content_not_blank"
  end
end
