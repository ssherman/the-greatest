# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The fill-blanks bookkeeping every author applier shares (spec §1):
      # one ledger fact per field, a value written only into a blank, and a
      # disagreement with a stored value recorded, never applied. An
      # identifier another author already holds is never stamped; the pair is
      # remembered for flag_collisions. The caller saves the author.
      class FactSheet
        attr_reader :author, :facts, :applied

        def initialize(author)
          @author = author
          @facts = {}
          @applied = []
          @collisions = {}
        end

        def record(name, value, applied:, reason:, **extra)
          facts[name] = {"value" => value, "applied" => applied, "reason" => reason}.merge(extra.deep_stringify_keys)
          @applied << name if applied
        end

        def identifier_values(type)
          author.identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end

        # "filled", "already_set" or "held_by_other".
        def stamp(type, value)
          return "already_set" if identifier_values(type).include?(value)

          other = ::Identifier.where(identifiable_type: "Books::Author", identifier_type: type, value: value)
            .where.not(identifiable_id: author.id).pick(:identifiable_id)
          if other
            (@collisions[other] ||= []) << {"type" => type, "value" => value}
            return "held_by_other"
          end

          author.identifiers.find_or_initialize_by(identifier_type: type, value: value)
          "filled"
        end

        # A type the author holds one value of: a different stored value is a conflict.
        def single_identifier(name, type, value)
          return record(name, nil, applied: false, reason: "null") if value.blank?

          stored = identifier_values(type)
          return record(name, value, applied: false, reason: "conflict", stored: stored) if stored.any? && !stored.include?(value)

          reason = stamp(type, value)
          record(name, value, applied: reason == "filled", reason: reason)
        end

        def year(name, value)
          current = author.public_send(name)
          if current.nil?
            author.public_send(:"#{name}=", value)
            record(name, value, applied: true, reason: "filled")
          elsif current == value
            record(name, value, applied: false, reason: "already_set")
          else
            record(name, value, applied: false, reason: "conflict", stored: current)
          end
        end

        # "unspecified" is the legacy AI's "don't know" (334 authors), so it
        # counts as blank. `source` is recorded beside a filled value.
        def gender(value, **source)
          current = author.gender
          if current.nil? || current == "unspecified"
            author.gender = value
            record("gender", value, applied: true, reason: "filled", **source)
          elsif current == value
            record("gender", value, applied: false, reason: "already_set")
          else
            record("gender", value, applied: false, reason: "conflict", stored: current)
          end
        end

        # A union, compared after normalization and case folding only: "García"
        # and "Garcia" are both kept, since each is a spelling someone searches.
        # Each name is added, and recorded, in the form it is stored.
        def alternate_names(offered, cap:)
          offered = offered.map { |name| normalize(name.to_s.squish) }.reject(&:blank?)
          taken = ([author.name] + Array(author.alternate_names)).map { |name| normalize(name).downcase }.to_set
          added = []
          offered.each do |name|
            key = name.downcase
            next if taken.include?(key)

            taken << key
            added << name
            break if added.size >= cap
          end
          if added.empty?
            return record("alternate_names", [], applied: false, reason: offered.empty? ? "null" : "already_set", offered: offered.size)
          end

          author.alternate_names = Array(author.alternate_names) + added
          record("alternate_names", added, applied: true, reason: "filled", offered: offered.size)
        end

        # Fills only when the author has no countries. The block maps the
        # source's values to a CountryLookup::Result and runs only when needed.
        # `source` is recorded beside a filled value.
        def countries(values, **source)
          return record("countries", [], applied: false, reason: "null", unmatched: []) if values.empty?
          return record("countries", values, applied: false, reason: "already_set", unmatched: []) if author.author_countries.exists?

          lookup = yield(values)
          return record("countries", values, applied: false, reason: "no_match", unmatched: lookup.unmatched) if lookup.countries.empty?

          lookup.countries.each { |country| author.author_countries.build(country: country) }
          record("countries", lookup.countries.map(&:name), applied: true, reason: "filled", unmatched: lookup.unmatched, **source)
        end

        def flag_collisions(reason:, decision:)
          @collisions.each do |other_id, identifiers|
            ::Services::DuplicateCandidates::Flag.call(
              item_type: "Books::Author", ids: [author.id, other_id], source: :external_key_collision,
              evidence: {reason: reason, identifiers: identifiers}, match_decision: decision
            )
          end
        end

        private

        def normalize(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s
        end
      end
    end
  end
end
