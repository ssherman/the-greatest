class TightenDescriptionSourceNameConstraint < ActiveRecord::Migration[8.1]
  # The original constraint was one-way: it required source_name for :other (9) but let
  # a named source keep a stale one. Since source_name sits inside the natural-key unique
  # index, a wikipedia row holding a leftover source_name and a wikipedia row with NULL
  # are distinct index entries, so both survive -- two descriptions of the same source for
  # one (describable, kind, locale). Making it biconditional closes that.
  def up
    remove_check_constraint :descriptions,
      name: "descriptions_other_requires_source_name"

    add_check_constraint :descriptions,
      "(source = 9 AND source_name IS NOT NULL) OR (source <> 9 AND source_name IS NULL)",
      name: "descriptions_source_name_matches_source"
  end

  def down
    remove_check_constraint :descriptions,
      name: "descriptions_source_name_matches_source"

    add_check_constraint :descriptions,
      "source <> 9 OR source_name IS NOT NULL",
      name: "descriptions_other_requires_source_name"
  end
end
