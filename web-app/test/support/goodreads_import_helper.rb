# frozen_string_literal: true

require "csv"

# Shared setup for the Goodreads import resolver tests: the finder's and the
# importer's outside services stubbed to "nothing found" (OpenSearch empty,
# Open Library abstaining), plus builders for export CSVs, editions and
# unmatched finder answers.
module GoodreadsImportHelper
  OPEN_LIBRARY_URL = "http://open-library.test:8080"
  EXPORT_HEADERS = ["Book Id", "Title", "Author", "Additional Authors", "ISBN", "ISBN13", "My Rating",
    "Year Published", "Original Publication Year", "Date Read", "Date Added", "Bookshelves",
    "Bookshelves with positions", "Exclusive Shelf", "My Review", "Private Notes", "Read Count"].freeze

  def stub_resolution_services(search_hits: [])
    client = ::Books::OpenLibrary::Client.new(
      config: ::Books::OpenLibrary::Configuration.new(base_url: OPEN_LIBRARY_URL),
      breaker: ::Books::OpenLibrary::CircuitBreaker.new(key: "test:goodreads:open_library", failure_threshold: 5,
        cooldown: 60, redis: ::Books::OpenLibrary::FakeRedis.new)
    )
    ::Books::OpenLibrary::Client.stubs(:new).returns(client)
    stub_request(:post, "#{OPEN_LIBRARY_URL}/resolve").to_return(status: 200, body: open_library_abstain.to_json)
    ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns(search_hits)
    ::Search::Books::Search::AuthorByName.stubs(:call).returns([])
    ::Books::EnrichBookJob.stubs(:perform_async)
    ::Books::Authors::WikidataJob.stubs(:perform_async)
    # Sidekiq runs inline in tests; a test that cares asserts on this.
    ::Books::Goodreads::FetchPageJob.stubs(:perform_async)
  end

  def open_library_abstain
    {
      "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
                           "pipeline_version" => 1, "matcher_version" => 2},
      "data" => {
        "decision" => {"verdict" => "abstain", "key" => nil, "score" => 0.0, "margin" => 0.0, "reason" => "test"},
        "guards_tripped" => [], "volume_guards_tripped" => [], "candidates" => []
      }
    }
  end

  def search_hit(book, score = 9.0)
    {id: book.id.to_s, score: score, source: {}}
  end

  def stub_matching_ai(selected_index:, confidence: "high")
    task = stub("select_candidate_task")
    task.stubs(:call).returns(::Services::Ai::Result.new(success: true, ai_chat: ai_chats(:general_chat),
      data: {selected_index: selected_index, confidence: confidence, reasoning: "test", same_entity_groups: []}))
    ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).returns(task)
  end

  # Each row is a hash keyed by export header; headers it omits are blank.
  def goodreads_csv(*rows)
    CSV.generate do |csv|
      csv << EXPORT_HEADERS
      rows.each { |row| csv << EXPORT_HEADERS.map { |header| row[header] } }
    end
  end

  def goodreads_rows(*rows)
    ::Books::Goodreads::ExportFile.parse(goodreads_csv(*rows)).data[:rows]
  end

  def goodreads_edition(**attributes)
    title = attributes.fetch(:title, "The Quiet Year")
    author = attributes.fetch(:primary_author, "Anna Brenner")
    ::Books::GoodreadsEdition.create!({
      goodreads_book_id: 90_000_000 + ::Books::GoodreadsEdition.count,
      signature: ::Books::Goodreads::ExportRow.signature(title, author),
      title: title, primary_author: author
    }.merge(attributes))
  end

  # A cached Goodreads page. authors: [name, role] pairs, the first credited
  # as primary. The defaults back goodreads_edition's defaults.
  def goodreads_page(goodreads_book_id:, title: "The Quiet Year", authors: [["Anna Brenner", "Author"]], outcome: :found, **attributes)
    found = outcome.to_sym == :found
    ::Books::GoodreadsPage.create!({
      goodreads_book_id: goodreads_book_id, source: :fetched, outcome: outcome, fetched_at: Time.current,
      title: (title if found),
      authors: found ? authors.each_with_index.map { |(name, role), index| {"name" => name, "role" => role, "primary" => index.zero?} } : []
    }.merge(attributes))
  end

  def unmatched_match(subject:, candidates: [], decided_by: :rule)
    decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: subject,
      outcome: :unmatched, confidence: :high, decided_by: decided_by)
    ::DataImporters::Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: decided_by,
      reason: "test", candidates: candidates, decision: decision)
  end
end
