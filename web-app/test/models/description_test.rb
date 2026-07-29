require "test_helper"

# == Schema Information
#
# Table name: descriptions
#
#  id               :bigint           not null, primary key
#  content          :text             not null
#  describable_type :string           not null
#  kind             :integer          default("summary"), not null
#  license          :integer
#  locale           :string           default("en"), not null
#  rank             :integer          default("normal"), not null
#  retrieved_at     :datetime
#  source           :integer          not null
#  source_name      :string
#  source_url       :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  describable_id   :bigint           not null
#
# Indexes
#
#  index_descriptions_on_describable          (describable_type,describable_id)
#  index_descriptions_on_describable_and_key  (describable_type,describable_id,kind,locale,source,source_name) UNIQUE NULLS NOT DISTINCT
#  index_descriptions_one_preferred_per_key   (describable_type,describable_id,kind,locale) UNIQUE WHERE (rank = 1)
#
class DescriptionTest < ActiveSupport::TestCase
  test "belongs to a polymorphic describable" do
    assert_equal Books::Book, descriptions(:war_and_peace_ai).describable.class
    assert_equal Music::Album, descriptions(:dark_side_ai).describable.class
    assert_equal Games::Game, descriptions(:botw_igdb).describable.class
  end

  test "requires content" do
    description = descriptions(:war_and_peace_ai)
    description.content = ""
    assert_not description.valid?
    assert_includes description.errors[:content], "can't be blank"
  end

  test "requires locale" do
    description = descriptions(:war_and_peace_ai)
    description.locale = ""
    assert_not description.valid?
    assert_includes description.errors[:locale], "can't be blank"
  end

  test "requires source_name only when source is other" do
    other = descriptions(:tolstoy_google)
    other.source_name = nil
    assert_not other.valid?
    assert_includes other.errors[:source_name], "can't be blank"

    wikipedia = descriptions(:war_and_peace_wikipedia)
    wikipedia.source_name = nil
    assert wikipedia.valid?
  end

  test "rank supports a negative deprecated value" do
    assert_equal(-1, Description.ranks["deprecated"])
    assert descriptions(:crime_deprecated).deprecated?
    assert descriptions(:crime_preferred).preferred?
    assert descriptions(:war_and_peace_ai).normal?
  end

  test "source and license are prefixed, kind and rank are not" do
    assert descriptions(:war_and_peace_wikipedia).source_wikipedia?
    assert descriptions(:war_and_peace_wikipedia).license_cc_by_sa_4?
    assert descriptions(:tolstoy_google).source_other?
    assert descriptions(:war_and_peace_ai).summary?
    assert descriptions(:war_and_peace_long).long?
  end

  test "rejects a duplicate of the natural key" do
    duplicate = Description.new(
      describable: books_books(:war_and_peace),
      kind: :summary, locale: "en", source: :ai_generated, content: "dupe"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:source], "has already been taken"
  end

  test "allows the same source at a different kind, locale, or describable" do
    assert Description.new(
      describable: books_books(:war_and_peace),
      kind: :blurb, locale: "en", source: :ai_generated, content: "different kind"
    ).valid?

    assert Description.new(
      describable: books_books(:war_and_peace),
      kind: :summary, locale: "de", source: :ai_generated, content: "different locale"
    ).valid?

    assert Description.new(
      describable: books_books(:crime_and_punishment),
      kind: :summary, locale: "en", source: :wikipedia, content: "different book"
    ).valid?
  end

  test "database rejects a duplicate natural key even when validations are skipped" do
    duplicate = Description.new(
      describable: books_books(:war_and_peace),
      kind: :summary, locale: "en", source: :ai_generated, content: "dupe"
    )
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save(validate: false) }
  end

  test "database rejects an other-sourced row with no source_name" do
    invalid = Description.new(
      describable: books_books(:war_and_peace),
      kind: :summary, locale: "en", source: :other, source_name: nil, content: "unattributed"
    )
    assert_raises(ActiveRecord::CheckViolation) { invalid.save(validate: false) }
  end

  test "database rejects blank content even when validations are skipped" do
    blank = Description.new(
      describable: books_books(:war_and_peace),
      kind: :blurb, locale: "en", source: :ai_generated, content: "   "
    )
    assert_raises(ActiveRecord::CheckViolation) { blank.save(validate: false) }
  end

  test "database rejects a second preferred row for the same describable, kind, and locale" do
    conflict = Description.new(
      describable: books_books(:crime_and_punishment),
      kind: :summary, locale: "en", source: :wikipedia, content: "a second preferred row", rank: :preferred
    )
    assert_raises(ActiveRecord::RecordNotUnique) { conflict.save(validate: false) }
  end
end
