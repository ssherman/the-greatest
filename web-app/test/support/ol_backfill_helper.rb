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

  # hits: {[type, value] => [IdentifierHit] or an exception to raise}
  # works: {key => Work or nil}
  # resolution: a Resolution, or a lambda given the resolve arguments
  # errors: one entry per call, in call order, whatever the call; nil means
  #   "no error for this call", an exception is raised by that call.
  class FakeOlClient
    attr_reader :calls

    def initialize(hits: {}, works: {}, resolution: nil, version: nil, errors: [])
      @hits = hits
      @works = works
      @resolution = resolution
      @version = version
      @errors = errors.dup
      @calls = []
    end

    def identifier(type, value)
      @calls << [:identifier, type, value]
      raise_next!
      found = @hits.fetch([type, value], [])
      raise found if found.is_a?(Exception)

      found
    end

    def works_batch(keys)
      @calls << [:works_batch, keys]
      raise_next!
      keys.to_h { |key| [key, @works[key]] }
    end

    def resolve(**args)
      @calls << [:resolve, args]
      raise_next!
      raise "no resolution stubbed" if @resolution.nil?

      @resolution.respond_to?(:call) ? @resolution.call(args) : @resolution
    end

    def version
      @calls << [:version]
      raise_next!
      @version
    end

    private

    def raise_next!
      error = @errors.shift
      raise error if error
    end
  end
end
