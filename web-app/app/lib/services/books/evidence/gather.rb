# frozen_string_literal: true

module Services
  module Books
    module Evidence
      # Gathers Wikidata, Wikipedia and WorldCat evidence for one book into a single
      # books.evidence ledger row. Every section is computed before the row is written,
      # so a Wikimedia rate limit (which propagates) leaves nothing behind. Any other
      # Wikimedia error, or a WorldCat error, marks that one source failed and the run
      # continues. Facts carry the date of the Wikidata dump the service answered
      # from (nil when Wikidata was not reached). Wikipedia is reached only through the Wikidata item's enwiki sitelink.
      class Gather
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.evidence"
        SCHEMA_VERSION = 3
        LIST_FIELDS = %w[countries languages genres main_subjects narrative_locations set_in_periods forms].freeze

        def self.call(book:, wikidata: nil, wikipedia: nil, worldcat: nil)
          http = evidence_http
          wikidata ||= ::Wikidata::Client.new
          wikipedia ||= ::Wikipedia::Client.new(http: http)
          new(book, wikidata, wikipedia, worldcat).call
        end

        # The shared Wikimedia settings with the longer inline wait of the evidence lane.
        # A copy: the config object is shared with every other Wikimedia user.
        def self.evidence_http_settings
          shared = Rails.application.config.x.wikimedia
          ActiveSupport::OrderedOptions.new.merge(shared.to_h.merge(max_inline_wait: shared.evidence_max_inline_wait))
        end

        def self.evidence_http
          ::Wikimedia::Http.new(settings: evidence_http_settings)
        end

        def initialize(book, wikidata, wikipedia, worldcat)
          @book = book
          @wikidata = wikidata
          @wikipedia = wikipedia
          @worldcat = worldcat
          @failed = []
          @errors = {}
        end

        def call
          resolution = resolve
          work = resolution&.dig(:work)
          wikidata_section = work && wikidata_section_for(work, resolution)
          wikipedia_section = (wikidata_section && work.enwiki_title.present?) ? wikipedia_section_for(work.enwiki_title) : nil
          worldcat_section = worldcat_section_for

          sections = [wikidata_section, wikipedia_section, worldcat_section]
          enrichment = @book.enrichments.create!(
            kind: KIND,
            outcome: sections.any? ? :applied : :nothing_to_apply,
            facts: {
              "schema_version" => SCHEMA_VERSION,
              "wikidata_qid" => resolution&.dig(:qid),
              "wikidata_dump_date" => @wikidata.dump_date,
              "wikidata" => wikidata_section,
              "wikipedia" => wikipedia_section,
              "worldcat" => worldcat_section,
              "wikidata_rejected" => resolution ? resolution[:rejected] : [],
              "wikidata_conflict_book_id" => resolution&.dig(:conflict_book_id),
              "sources_failed" => @failed,
              "source_errors" => @errors
            }
          )
          Result.new(success?: true, data: {enrichment: enrichment}, errors: [])
        end

        private

        def resolve
          ResolveWikidataWork.call(book: @book, client: @wikidata).data
        rescue ::Wikimedia::Exceptions::Error => error
          fail_source("wikidata", error)
        end

        def wikidata_section_for(work, resolution)
          ids = LIST_FIELDS.flat_map { |field| work.public_send(field) }.uniq
          labels = ids.empty? ? {} : @wikidata.labels(ids)
          section = {"qid" => work.id, "via" => resolution[:via], "label" => work.label, "description" => work.description}
          LIST_FIELDS.each { |field| section[field] = work.public_send(field).filter_map { |id| labels[id].presence } }
          section["publication_years"] = work.publication_years
          section["enwiki_title"] = work.enwiki_title
          section["country_ids"] = work.countries
          section["country_matches"] = country_matches(work.countries)
          section
        rescue ::Wikimedia::Exceptions::Error => error
          fail_source("wikidata", error)
        end

        # Books::Country names for the work's P495 items. Raises like any Wikidata call.
        def country_matches(ids)
          return [] if ids.empty?

          ::Services::Books::CountryLookup.from_wikidata(ids, client: @wikidata).countries.map(&:name)
        end

        def wikipedia_section_for(title)
          article = @wikipedia.article(language: "en", title: title)
          return unless article

          {"title" => article.title, "url" => article.url, "lead" => article.lead,
           "plot" => article.plot, "infobox" => article.infobox}
        rescue ::Wikimedia::Exceptions::Error => error
          fail_source("wikipedia", error)
        end

        def worldcat_section_for
          WorldCatSection.call(book: @book, client: @worldcat || ::Books::WorldCat::Client.new)
        rescue ::Books::WorldCat::Exceptions::Error => error
          fail_source("worldcat", error)
        end

        # Records the failure on the row and in the log; always returns nil (the section).
        def fail_source(source, error)
          @failed << source unless @failed.include?(source)
          @errors[source] = "#{error.class}: #{error.message}".slice(0, 200)
          Rails.logger.warn("Books::Evidence::Gather book #{@book.id}: #{source} failed (#{@errors[source]})")
          nil
        end
      end
    end
  end
end
