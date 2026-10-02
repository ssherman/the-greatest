# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Undoes what one author-step run applied, from the facts its ledger
      # row recorded (spec §12): the identifiers it stamped, the Wikipedia
      # link it added, the alternate names and countries it added, the legacy
      # Wikipedia descriptions it deprecated or restored, and each year or
      # gender it wrote that still holds the value written. A value changed
      # since is a person's, and stays. Only facts marked applied are
      # touched, and only this author's rows. Saves the author.
      class RevertFacts
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        IDENTIFIERS = {
          "wikidata_qid" => "books_author_wikidata_qid",
          "viaf" => "books_author_viaf",
          "isni" => "books_author_isni",
          "lcnaf" => "books_author_lcnaf",
          "goodreads_id" => "books_author_goodreads_id",
          "librarything_id" => "books_author_librarything_id"
        }.freeze
        OPEN_LIBRARY = "books_author_openlibrary_id"
        SCALARS = %w[birth_year death_year gender].freeze

        def self.call(author:, facts:)
          new(author: author, facts: facts).call
        end

        def initialize(author:, facts:)
          @author = author
          @facts = facts.to_h
        end

        def call
          reverted = @facts.filter_map do |name, fact|
            name if fact.is_a?(Hash) && fact["applied"] == true && revert(name, fact)
          end
          author.identifiers.reset
          author.author_countries.reset
          author.external_links.reset
          author.save!
          Result.new(success?: true, data: {reverted: reverted}, errors: [])
        end

        private

        attr_reader :author

        # true when something was undone.
        def revert(name, fact)
          case name
          when *IDENTIFIERS.keys then destroy(author.identifiers.where(identifier_type: IDENTIFIERS.fetch(name), value: fact["value"].to_s))
          when "openlibrary_ids" then destroy(author.identifiers.where(identifier_type: OPEN_LIBRARY, value: Array(fact["added"]).map(&:to_s)))
          when *SCALARS then clear(name, fact["value"])
          when "alternate_names" then remove_alternate_names(Array(fact["value"]))
          when "countries" then destroy(added_countries(fact))
          when "wikipedia" then destroy(author.external_links.where(url: fact["value"].to_s))
          when "legacy_wikipedia" then undo_legacy(Array(fact["value"]))
          else false
          end
        end

        def destroy(scope)
          rows = scope.to_a
          rows.each(&:destroy!)
          rows.any?
        end

        def clear(name, value)
          return false if value.nil? || author.public_send(name).to_s != value.to_s

          author.public_send(:"#{name}=", nil)
          true
        end

        def remove_alternate_names(names)
          keys = names.map { |name| name_key(name) }.to_set
          current = Array(author.alternate_names)
          kept = current.reject { |name| keys.include?(name_key(name)) }
          return false if kept.size == current.size

          author.alternate_names = kept
          true
        end

        # Ledger rows written before country ids were recorded name the countries.
        def added_countries(fact)
          return author.author_countries.where(country_id: Array(fact["country_ids"])) if fact.key?("country_ids")

          author.author_countries.joins(:country).where(books_countries: {name: Array(fact["value"])})
        end

        # A description the run deprecated goes back to normal (every legacy
        # Wikipedia description was migrated at normal rank, and normal never
        # collides with the one-preferred index); one it restored is
        # deprecated again. The next Wikidata run judges them afresh.
        def undo_legacy(verdicts)
          deprecated = description_ids(verdicts, "deprecated")
          restored = description_ids(verdicts, "restored")
          rows = author.descriptions.select do |row|
            (deprecated.include?(row.id) && row.deprecated?) || (restored.include?(row.id) && !row.deprecated?)
          end
          rows.each { |row| row.update!(rank: row.deprecated? ? :normal : :deprecated) }
          rows.any?
        end

        def description_ids(verdicts, verdict) = verdicts.select { |entry| entry["verdict"] == verdict }.map { |entry| entry["description_id"] }

        def name_key(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s.downcase
        end
      end
    end
  end
end
