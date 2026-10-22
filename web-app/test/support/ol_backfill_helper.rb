# frozen_string_literal: true

# Builders for the Open Library key backfill's tests: Work, IdentifierHit and
# Resolution values, and a client stand-in that records its calls.
module OlBackfillHelper
  SOURCE_VERSION = {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
                    "pipeline_version" => 1, "matcher_version" => 3}.freeze

  # authors: [[author_key, name], ...]
  def ol_work(key, title:, subtitle: nil, authors: [], redirected_from: [], source_version: SOURCE_VERSION)
    ::Books::OpenLibrary::Work.from_record({
      "key" => {"source" => "openlibrary", "key" => key}, "title" => title, "subtitle" => subtitle,
      "authors" => authors.map { |author_key, name| {"key" => {"source" => "openlibrary", "key" => author_key}, "name" => name} },
      "subjects" => [], "redirected_from" => redirected_from.map { |old| {"source" => "openlibrary", "key" => old} }
    }, source_version: source_version)
  end

  def ol_author(key, name:, alternate_names: [])
    ::Books::OpenLibrary::Author.from_record({
      "key" => {"source" => "openlibrary", "key" => key}, "name" => name, "alternate_names" => alternate_names
    }, source_version: SOURCE_VERSION)
  end

  def ol_edition(key, title:, subtitle: nil, publish_year: nil, isbn13: [], isbn10: [], oclc: [], goodreads: [], language_code: "eng")
    ::Books::OpenLibrary::Edition.from_record({
      "key" => {"source" => "openlibrary", "key" => key}, "title" => title, "subtitle" => subtitle,
      "publish_year" => publish_year, "language_code" => language_code,
      "isbn13" => isbn13, "isbn10" => isbn10, "oclc" => oclc, "goodreads" => goodreads
    })
  end

  def ol_hit(work_key, id_type: "isbn13", value: "9780140447934")
    ::Books::OpenLibrary::IdentifierHit.new(work_key: work_key, source: "openlibrary", redirected_from: [],
      edition_keys: [], id_type: id_type, value: value)
  end

  # A /resolve answer. With `work`, that work is the only candidate; an
  # "accept" verdict makes it the accepted one.
  def ol_resolution(verdict:, work: nil, duplicates: [], redirect_sources: [], source_version: SOURCE_VERSION)
    candidates = []
    if work
      candidates << ::Books::OpenLibrary::Candidate.new(
        work_key: work.key, source: "openlibrary", score: 0.9, rules: ["title_author"], margin: 0.3, verdict: verdict,
        evidence: {}, conflicting_features: [], diff: [], record: work, redirect_sources: redirect_sources
      )
    end
    ::Books::OpenLibrary::Resolution.new(
      decision: ::Books::OpenLibrary::Resolution::Decision.new(
        verdict: verdict, key: ((verdict == "accept") ? work&.key : nil), score: 0.9, margin: 0.3, reason: "test",
        duplicates: duplicates, duplicate_redirect_sources: []
      ),
      candidates: candidates, guards_tripped: [], volume_guards_tripped: [],
      source_version: source_version.deep_symbolize_keys
    )
  end

  # A /resolve answer with several candidates, in rank order. Each candidate
  # is {work:, verdict:, score:, conflicts: []}; `verdict` is the decision.
  def ol_resolution_with(verdict:, candidates:, reason: "test", volume_guards_tripped: [], source_version: SOURCE_VERSION)
    built = candidates.map do |candidate|
      ::Books::OpenLibrary::Candidate.new(
        work_key: candidate[:work].key, source: "openlibrary", score: candidate.fetch(:score, 0.9), rules: ["title_author"],
        margin: 0.0, verdict: candidate.fetch(:verdict, "abstain"), evidence: {},
        conflicting_features: candidate.fetch(:conflicts, []), diff: [], record: candidate[:work], redirect_sources: []
      )
    end
    ::Books::OpenLibrary::Resolution.new(
      decision: ::Books::OpenLibrary::Resolution::Decision.new(
        verdict: verdict, key: ((verdict == "accept") ? built.first&.work_key : nil), score: 0.9, margin: 0.0, reason: reason,
        duplicates: [], duplicate_redirect_sources: []
      ),
      candidates: built, guards_tripped: [], volume_guards_tripped: volume_guards_tripped,
      source_version: source_version.deep_symbolize_keys
    )
  end

  # hits: {[type, value] => [IdentifierHit] or an exception to raise}
  # works: {key => Work or nil}
  # authors: {key => Author or nil}
  # resolution: a Resolution, or a lambda given the resolve arguments
  # errors: one entry per call, in call order, whatever the call; nil means
  #   "no error for this call", an exception is raised by that call.
  class FakeOlClient
    # Called from threads (the fast pass looks identifiers up concurrently).
    def calls = @lock.synchronize { @calls.dup }

    def initialize(hits: {}, works: {}, authors: {}, resolution: nil, version: nil, errors: [], editions: {})
      @hits = hits
      @works = works
      @authors = authors
      @editions = editions
      @resolution = resolution
      @version = version
      @errors = errors.dup
      @calls = []
      @lock = Mutex.new
    end

    def identifier(type, value)
      record([:identifier, type, value])
      raise_next!
      found = @hits.fetch([type, value], [])
      raise found if found.is_a?(Exception)

      found
    end

    def works_batch(keys)
      record([:works_batch, keys])
      raise_next!
      keys.to_h { |key| [key, @works[key]] }
    end

    def authors_batch(keys)
      record([:authors_batch, keys])
      raise_next!
      keys.to_h { |key| [key, @authors[key]] }
    end

    def editions(key)
      record([:editions, key])
      raise_next!
      @editions.fetch(key, [])
    end

    def resolve(**args)
      record([:resolve, args])
      raise_next!
      raise "no resolution stubbed" if @resolution.nil?

      @resolution.respond_to?(:call) ? @resolution.call(args) : @resolution
    end

    def version
      record([:version])
      raise_next!
      @version
    end

    private

    def record(call) = @lock.synchronize { @calls << call }

    def raise_next!
      error = @lock.synchronize { @errors.shift }
      raise error if error
    end
  end

  def wc_record(oclc:, title:, creator: nil, contributors: [], year: nil, isbn13s: [])
    ::Books::WorldCat::Record.from_hash({"oclc" => oclc, "title" => title, "creator" => creator,
      "contributors" => contributors, "year" => year, "isbn13s" => isbn13s})
  end

  class FakeWcClient
    attr_reader :calls

    def initialize(records: {}, version: {dump_date: "2025-09-04"}, errors: [])
      @records = records
      @version = version
      @errors = errors.dup
      @calls = []
    end

    def record_by_isbn(isbn)
      @calls << [:record_by_isbn, isbn]
      error = @errors.shift
      raise error if error

      @records.fetch(isbn, [])
    end

    def version
      @calls << [:version]
      @version
    end
  end
end
