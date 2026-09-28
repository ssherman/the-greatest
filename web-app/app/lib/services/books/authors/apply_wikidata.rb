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
          @facts = {}
          @applied = []
          @collisions = {}
        end

        # A held id Wikidata has merged into this item is the same person, so
        # only another live id is a conflict.
        def call
          other_qids = values_of(QID) - [entity.id] - @redirected_ids
          if other_qids.any?
            record("wikidata_qid", entity.id, applied: false, reason: "held_qid_conflict", held: other_qids)
            return result(conflict: true)
          end

          apply_qid
          apply_single_identifiers
          apply_open_library_ids
          apply_year("birth_year", entity.birth)
          apply_year("death_year", entity.death)
          apply_gender
          apply_alternate_names
          apply_countries
          author.save!
          flag_collisions
          result(conflict: false)
        end

        private

        attr_reader :author, :entity, :decision, :facts, :applied

        def result(conflict:)
          Result.new(success?: true, data: {facts: facts, applied: applied, conflict: conflict}, errors: [])
        end

        def record(name, value, applied:, reason:, **extra)
          facts[name] = {"value" => value, "applied" => applied, "reason" => reason}.merge(extra.deep_stringify_keys)
          self.applied << name if applied
        end

        def values_of(type)
          author.identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end

        # "filled", "already_set" or "held_by_other".
        def stamp(type, value)
          return "already_set" if values_of(type).include?(value)

          other = ::Identifier.where(identifiable_type: "Books::Author", identifier_type: type, value: value)
            .where.not(identifiable_id: author.id).pick(:identifiable_id)
          if other
            (@collisions[other] ||= []) << {"type" => type, "value" => value}
            return "held_by_other"
          end

          author.identifiers.find_or_initialize_by(identifier_type: type, value: value)
          "filled"
        end

        def apply_qid
          reason = stamp(QID, entity.id)
          extra = @redirected_ids.any? ? {redirected_from: @redirected_ids} : {}
          record("wikidata_qid", entity.id, applied: reason == "filled", reason: reason, **extra)
        end

        def apply_single_identifiers
          SINGLE_IDENTIFIERS.each do |type, kind|
            name = type.delete_prefix("books_author_")
            value = entity.identifiers(kind).first&.delete(" ")
            next record(name, nil, applied: false, reason: "null") if value.blank?

            stored = values_of(type)
            next record(name, value, applied: false, reason: "conflict", stored: stored) if stored.any? && !stored.include?(value)

            reason = stamp(type, value)
            record(name, value, applied: reason == "filled", reason: reason)
          end
        end

        def apply_open_library_ids
          values = entity.identifiers("openlibrary").map { |value| value.delete(" ") }.uniq
          return record("openlibrary_ids", [], applied: false, reason: "null") if values.empty?

          outcomes = values.index_with { |value| stamp(OPEN_LIBRARY, value) }
          added = outcomes.select { |_value, reason| reason == "filled" }.keys
          reason = if added.any? then "filled"
          elsif outcomes.values.all?("already_set") then "already_set"
          else "held_by_other"
          end
          record("openlibrary_ids", values, applied: added.any?, reason: reason, added: added, outcomes: outcomes)
        end

        def apply_year(name, fact)
          return record(name, nil, applied: false, reason: fact.reason) if fact.year.nil?

          current = author.public_send(name)
          if current.nil?
            author.public_send(:"#{name}=", fact.year)
            record(name, fact.year, applied: true, reason: "filled")
          elsif current == fact.year
            record(name, fact.year, applied: false, reason: "already_set")
          else
            record(name, fact.year, applied: false, reason: "conflict", stored: current)
          end
        end

        # "unspecified" is the legacy AI's "don't know" (334 authors), so it
        # counts as blank.
        def apply_gender
          ids = entity.gender_ids
          return record("gender", nil, applied: false, reason: "null") if ids.empty?

          mapped = ids.map { |id| GENDERS[id] }.uniq
          return record("gender", ids, applied: false, reason: "unmapped") if mapped.include?(nil) || mapped.size > 1

          value = mapped.first
          current = author.gender
          if current.nil? || current == "unspecified"
            author.gender = value
            record("gender", value, applied: true, reason: "filled", wikidata: ids)
          elsif current == value
            record("gender", value, applied: false, reason: "already_set")
          else
            record("gender", value, applied: false, reason: "conflict", stored: current)
          end
        end

        # Compared after normalization and case folding only: "García" and
        # "Garcia" are both kept, since each is a spelling someone searches.
        def apply_alternate_names
          offered = ([entity.label] + entity.aliases + entity.native_names + entity.pseudonyms)
            .map { |name| normalize(name.to_s.squish) }.reject(&:blank?)
          taken = ([author.name] + Array(author.alternate_names)).map { |name| normalize(name).downcase }.to_set
          added = []
          offered.each do |name|
            key = name.downcase
            next if taken.include?(key)

            taken << key
            added << name
            break if added.size >= ALTERNATE_NAME_CAP
          end
          if added.empty?
            return record("alternate_names", [], applied: false, reason: offered.empty? ? "null" : "already_set", offered: offered.size)
          end

          author.alternate_names = Array(author.alternate_names) + added
          record("alternate_names", added, applied: true, reason: "filled", offered: offered.size)
        end

        def apply_countries
          ids = entity.citizenship_ids
          return record("countries", [], applied: false, reason: "null", unmatched: []) if ids.empty?
          return record("countries", ids, applied: false, reason: "already_set", unmatched: []) if author.author_countries.exists?

          lookup = @country_lookup.from_wikidata(ids)
          return record("countries", ids, applied: false, reason: "no_match", unmatched: lookup.unmatched) if lookup.countries.empty?

          lookup.countries.each { |country| author.author_countries.build(country: country) }
          record("countries", lookup.countries.map(&:name), applied: true, reason: "filled", unmatched: lookup.unmatched, wikidata: ids)
        end

        def flag_collisions
          @collisions.each do |other_id, identifiers|
            ::Services::DuplicateCandidates::Flag.call(
              item_type: "Books::Author", ids: [author.id, other_id], source: :external_key_collision,
              evidence: {reason: "Wikidata #{entity.id} lists identifiers another author already holds", identifiers: identifiers},
              match_decision: decision
            )
          end
        end

        def normalize(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s
        end
      end
    end
  end
end
