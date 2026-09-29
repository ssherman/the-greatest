# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Writes what a matched Wikidata item says onto the author, filling
      # blanks only (spec §6). Never writes name or kind. A value that
      # disagrees with a stored one is a recorded conflict, never applied;
      # an identifier another author holds is flagged as a duplicate pair,
      # never stamped on a second author. Returns the ledger facts.
      class ApplyWikidata
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        ALTERNATE_NAME_CAP = 20
        QID = "books_author_wikidata_qid"
        OPEN_LIBRARY = "books_author_openlibrary_id"
        GENDERS = {
          "Q6581097" => "male", "Q6581072" => "female",
          "Q1052281" => "female", # trans woman
          "Q2449503" => "male", # trans man
          "Q48270" => "non_binary"
        }.freeze
        # identifier type => Distiller kind; one value each. Every Open Library
        # value is stamped (apply_open_library_ids): Wikidata often lists
        # several for one person, and each helps the finder.
        SINGLE_IDENTIFIERS = {
          "books_author_viaf" => "viaf",
          "books_author_isni" => "isni",
          "books_author_lcnaf" => "lcnaf",
          "books_author_goodreads_id" => "goodreads",
          "books_author_librarything_id" => "librarything"
        }.freeze

        def self.call(author:, entity:, decision: nil, client: nil, country_lookup: nil, redirected_ids: [])
          new(author: author, entity: entity, decision: decision, client: client, country_lookup: country_lookup,
            redirected_ids: redirected_ids).call
        end

        def initialize(author:, entity:, decision:, client:, country_lookup:, redirected_ids:)
          @author = author
          @entity = entity
          @decision = decision
          @country_lookup = country_lookup || ::Services::Books::CountryLookup.new(client: client)
          @redirected_ids = Array(redirected_ids)
          @sheet = FactSheet.new(author)
        end

        # A held id Wikidata has merged into this item is the same person, so
        # only another live id is a conflict.
        def call
          other_qids = sheet.identifier_values(QID) - [entity.id] - @redirected_ids
          if other_qids.any?
            sheet.record("wikidata_qid", entity.id, applied: false, reason: "held_qid_conflict", held: other_qids)
            return result(conflict: true)
          end

          apply_qid
          SINGLE_IDENTIFIERS.each do |type, kind|
            sheet.single_identifier(type.delete_prefix("books_author_"), type, entity.identifiers(kind).first&.delete(" "))
          end
          apply_open_library_ids
          apply_year("birth_year", entity.birth)
          apply_year("death_year", entity.death)
          apply_gender
          sheet.alternate_names([entity.label] + entity.aliases + entity.native_names + entity.pseudonyms, cap: ALTERNATE_NAME_CAP)
          sheet.countries(entity.citizenship_ids, wikidata: entity.citizenship_ids) { |ids| @country_lookup.from_wikidata(ids) }
          author.save!
          sheet.flag_collisions(reason: "Wikidata #{entity.id} lists identifiers another author already holds", decision: decision)
          result(conflict: false)
        end

        private

        attr_reader :author, :entity, :decision, :sheet

        def result(conflict:)
          Result.new(success?: true, data: {facts: sheet.facts, applied: sheet.applied, conflict: conflict}, errors: [])
        end

        def apply_qid
          reason = sheet.stamp(QID, entity.id)
          extra = @redirected_ids.any? ? {redirected_from: @redirected_ids} : {}
          sheet.record("wikidata_qid", entity.id, applied: reason == "filled", reason: reason, **extra)
        end

        def apply_open_library_ids
          values = entity.identifiers("openlibrary").map { |value| value.delete(" ") }.uniq
          return sheet.record("openlibrary_ids", [], applied: false, reason: "null") if values.empty?

          outcomes = values.index_with { |value| sheet.stamp(OPEN_LIBRARY, value) }
          added = outcomes.select { |_value, reason| reason == "filled" }.keys
          reason = if added.any? then "filled"
          elsif outcomes.values.all?("already_set") then "already_set"
          else "held_by_other"
          end
          sheet.record("openlibrary_ids", values, applied: added.any?, reason: reason, added: added, outcomes: outcomes)
        end

        def apply_year(name, fact)
          return sheet.record(name, nil, applied: false, reason: fact.reason) if fact.year.nil?

          sheet.year(name, fact.year)
        end

        def apply_gender
          ids = entity.gender_ids
          return sheet.record("gender", nil, applied: false, reason: "null") if ids.empty?

          mapped = ids.map { |id| GENDERS[id] }.uniq
          return sheet.record("gender", ids, applied: false, reason: "unmapped") if mapped.include?(nil) || mapped.size > 1

          sheet.gender(mapped.first, wikidata: ids)
        end
      end
    end
  end
end
