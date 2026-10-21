require "test_helper"

# == Schema Information
#
# Table name: enrichments
#
#  id                :bigint           not null, primary key
#  citations         :jsonb            not null
#  confidence        :integer
#  enrichable_type   :string           not null
#  error             :text
#  facts             :jsonb            not null
#  kind              :string           not null
#  mode              :integer          default("knowledge"), not null
#  model             :string
#  outcome           :integer          not null
#  provider          :string
#  reason            :string
#  recognized        :boolean
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  ai_chat_id        :bigint
#  enrichable_id     :bigint           not null
#  match_decision_id :bigint
#  workflow_step_id  :bigint
#
# Indexes
#
#  index_enrichments_on_ai_chat_id           (ai_chat_id)
#  index_enrichments_on_enrichable           (enrichable_type,enrichable_id)
#  index_enrichments_on_kind                 (kind)
#  index_enrichments_on_match_decision_id    (match_decision_id)
#  index_enrichments_on_mode_and_created_at  (mode,created_at)
#  index_enrichments_on_outcome              (outcome)
#  index_enrichments_on_workflow_step_id     (workflow_step_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_chat_id => ai_chats.id) ON DELETE => nullify
#  fk_rails_...  (match_decision_id => match_decisions.id) ON DELETE => nullify
#  fk_rails_...  (workflow_step_id => workflow_steps.id) ON DELETE => nullify
#
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

    ["Books.book_facts", "a.b.c", "books.book-facts", " books.book_facts", "books.book_facts\n"].each do |candidate|
      row.kind = candidate
      assert_not row.valid?, "expected #{candidate.inspect} to be invalid"
    end
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
    travel_to(enrichments(:crime_and_punishment_research_skipped).created_at) do
      assert_includes Enrichment.today, enrichments(:crime_and_punishment_research_skipped)
      assert_not_includes Enrichment.today, enrichments(:war_and_peace_research_old)
    end
  end

  test "today starts at the beginning of the current day, not a rolling window" do
    travel_to Time.utc(2026, 9, 24, 12, 0, 0) do
      book = books_books(:war_and_peace)
      yesterday = Enrichment.create!(enrichable: book, kind: "books.book_facts", outcome: :skipped, created_at: Time.current.beginning_of_day - 1.second)
      today = Enrichment.create!(enrichable: book, kind: "books.book_facts", outcome: :skipped, created_at: Time.current.beginning_of_day)

      assert_includes Enrichment.today, today
      assert_not_includes Enrichment.today, yesterday
    end
  end

  test "research scope combines with today for the budget count" do
    travel_to(enrichments(:crime_and_punishment_research_skipped).created_at) do
      assert_equal 1, Enrichment.research.today.count
    end
  end

  test "low_confidence_on finds rows by a fact's confidence" do
    assert_includes Enrichment.low_confidence_on(:word_count), enrichments(:war_and_peace_facts_applied)
    assert_not_includes Enrichment.low_confidence_on(:first_published_year), enrichments(:war_and_peace_facts_applied)
  end

  test "stamps the current workflow step on create" do
    step = workflow_steps(:tolstoy_wikidata)
    row = Current.set(workflow_step_id: step.id) do
      books_authors(:tolstoy).enrichments.create!(kind: "books.author_facts", outcome: :skipped, reason: "test")
    end
    assert_equal step.id, row.workflow_step_id
  end

  test "has no workflow step when created outside a step" do
    row = books_authors(:tolstoy).enrichments.create!(kind: "books.author_facts", outcome: :skipped, reason: "test")
    assert_nil row.workflow_step_id
  end

  test "keeps its row when its workflow step is deleted" do
    step = workflow_steps(:tolstoy_wikidata)
    row = Current.set(workflow_step_id: step.id) do
      books_authors(:tolstoy).enrichments.create!(kind: "books.author_facts", outcome: :skipped, reason: "test")
    end
    step.delete
    assert_nil row.reload.workflow_step_id
  end

  test "confidence enum is prefixed" do
    assert enrichments(:war_and_peace_facts_applied).confidence_high?
    assert enrichments(:crime_and_punishment_unrecognized).confidence_low?
  end
end
