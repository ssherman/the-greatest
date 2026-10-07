# frozen_string_literal: true

# Builders for the list wizard core's tests (books list wizard spec): a books
# list, wizard rows, and finder answers that carry a persisted MatchDecision.
module ListWizardHelper
  def wizard_list(name: "Wizard Test List", raw_content: "<ol><li>War and Peace by Leo Tolstoy</li></ol>")
    ::Books::List.create!(name: name, status: :unapproved, raw_content: raw_content)
  end

  def wizard_row(list, position:, title:, authors: [], subtitle: nil, year: nil, listable: nil, verified: false, wizard: {})
    attributes = {
      position: position, verified: verified,
      metadata: {
        "title" => title, "subtitle" => subtitle, "authors" => authors, "year" => year,
        "wizard" => {"bucket" => "pending", "reasons" => [], "settled" => false}.merge(wizard.deep_stringify_keys)
      }
    }
    if listable
      attributes[:listable] = listable
    else
      attributes[:listable_type] = "Books::Book"
    end
    list.list_items.create!(attributes)
  end

  def wizard_match(subject:, outcome:, record: nil, confidence: :high, decided_by: :rule, external: nil,
    candidates: [], external_resolution: nil, sources_failed: [])
    decision = ::MatchDecision.create!(
      finder: "DataImporters::Books::Book::Finder", subject: subject, record: record, outcome: outcome,
      confidence: confidence, decided_by: decided_by, query: {}, candidates: candidates.map(&:snapshot),
      needs_review: %i[medium low].include?(confidence) || decided_by == :fallback
    )
    ::DataImporters::Match.new(
      outcome: outcome, record: record, confidence: confidence, decided_by: decided_by, reason: "test",
      candidates: candidates, external: external, external_resolution: external_resolution, decision: decision,
      sources_failed: sources_failed
    )
  end

  def ol_candidate(key, verdict: "accept", title: "An Open Library Work", creators: [], year: nil)
    ::DataImporters::Candidate.new(
      external_key: key, external_source: :open_library, sources: [:open_library], scores: {open_library: 0.9},
      evidence: {external_verdict: verdict, title: title, creators: creators, year: year}
    )
  end

  def local_candidate(book, list_count: 0)
    ::DataImporters::Candidate.new(
      record: book, sources: [:exact],
      evidence: {title: book.title, creators: book.authors.map(&:name), year: book.first_published_year, list_count: list_count}
    )
  end

  # A finder stand-in. Each call answers with the next answer given (the last
  # one repeats); an answer that responds to #call gets the row, so a test can
  # build a match whose decision belongs to that row.
  class FakeFinder
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls = []
    end

    def call(query:, subject: nil, verify: false, exclude: nil)
      @calls << {query: query, subject: subject}
      answer = (@answers.size > 1) ? @answers.shift : @answers.first
      answer.respond_to?(:call) ? answer.call(subject) : answer
    end
  end
end
