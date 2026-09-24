require "test_helper"

class EnrichmentTest < ActiveSupport::TestCase
  test "fixtures cover every outcome" do
    assert_equal Enrichment.outcomes.keys.sort, Enrichment.distinct.pluck(:outcome).sort
  end

  test "belongs to a polymorphic enrichable" do
    row = enrichments(:war_and_peace_facts_applied)
    assert_equal books_books(:war_and_peace), row.enrichable
  end

  test "requires a namespaced kind" do
    row = Enrichment.new(enrichable: books_books(:war_and_peace), kind: "book_facts", outcome: :applied)
    assert_not row.valid?
    assert_includes row.errors[:kind], "is invalid"

    row.kind = "books.book_facts"
    assert row.valid?
  end

  test "ai_chat is optional" do
    row = enrichments(:crime_and_punishment_research_skipped)
    assert_nil row.ai_chat
    assert row.valid?
  end

  test "for_kind scopes by kind" do
    assert_includes Enrichment.for_kind("books.book_facts"), enrichments(:war_and_peace_facts_applied)
    assert_empty Enrichment.for_kind("music.album_facts")
  end

  test "today excludes rows created before midnight" do
    assert_includes Enrichment.today, enrichments(:crime_and_punishment_research_skipped)
    assert_not_includes Enrichment.today, enrichments(:war_and_peace_research_old)
  end

  test "research scope combines with today for the budget count" do
    assert_equal 1, Enrichment.research.today.count
  end

  test "low_confidence_on finds rows by a fact's confidence" do
    assert_includes Enrichment.low_confidence_on(:word_count), enrichments(:war_and_peace_facts_applied)
    assert_not_includes Enrichment.low_confidence_on(:first_published_year), enrichments(:war_and_peace_facts_applied)
  end

  test "confidence enum is prefixed" do
    assert enrichments(:war_and_peace_facts_applied).confidence_high?
    assert enrichments(:crime_and_punishment_unrecognized).confidence_low?
  end
end
