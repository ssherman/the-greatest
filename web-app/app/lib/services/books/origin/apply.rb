# frozen_string_literal: true

module Services
  module Books
    module Origin
      # Decides whether an origin answer (a nationality and a confidence) may be
      # written to a book's country, and writes it if so. Deterministic. It never
      # overwrites a real country; a well-supported answer that differs from the
      # held one is reported as a disagreement instead.
      #
      # data[:country] is the matched country's name whenever CountryLookup
      # matched, applied or not. It is nil for null, placeholder_answer and
      # no_match, so a later task can read a disagreement's proposed country.
      class Apply
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        INFOBOX_SPLIT = %r{\s*(?:,|;|/|\sand\s)\s*}

        def self.call(book:, dossier:, nationality:, confidence:)
          new(book: book, dossier: dossier, nationality: nationality, confidence: confidence).call
        end

        def initialize(book:, dossier:, nationality:, confidence:)
          @book = book
          @dossier = dossier
          @nationality = nationality.to_s.strip
          @confidence = confidence.to_s.strip.downcase
        end

        def call
          return finish("null") if @nationality.blank?
          return finish("placeholder_answer") if CountryLookup::PLACEHOLDERS.include?(@nationality.downcase)

          @answer = CountryLookup.from_text([@nationality]).countries.first
          return finish("no_match", raw: @nationality) unless @answer

          @held = @dossier.real_countries.map(&:name)
          return decide_held if @held.any?

          decide_empty
        end

        private

        def decide_held
          return finish("already_set") if @held.include?(@answer.name)
          return finish("disagreement") if @confidence == "high" && wikidata_matches.include?(@answer.name)

          finish("already_set")
        end

        def decide_empty
          case @confidence
          when "high" then write
          when "medium" then supported? ? write : finish("unsupported")
          else finish("low_confidence")
          end
        end

        def supported?
          return true if wikidata_matches.include?(@answer.name)
          return true if research_backed_match?

          infobox = @dossier.wikipedia&.dig("infobox_country").to_s
          return false if infobox.blank?

          CountryLookup.from_text(infobox.split(INFOBOX_SPLIT)).countries.map(&:name).include?(@answer.name)
        end

        # book_facts researched this book on the web and named the same country.
        def research_backed_match?
          return false unless @dossier.research_backed?

          CountryLookup.from_text(Array(@dossier.book_facts["origin_countries"])).countries.map(&:name).include?(@answer.name)
        end

        def wikidata_matches
          Array(@dossier.wikidata&.dig("country_matches"))
        end

        def write
          replaced = []
          fresh = nil
          ActiveRecord::Base.transaction do
            # The dossier predates the AI call; re-read under a lock so a country
            # that landed in the gap is never overwritten.
            @book.lock!
            rows = @book.book_countries.includes(:country).to_a
            fresh = rows.reject { |bc| CountryLookup::PLACEHOLDERS.include?(bc.country.name.downcase) }
            next if fresh.any?

            rows.each do |bc|
              replaced << bc.country.name
              bc.destroy!
            end
            @book.book_countries.create_or_find_by!(country: @answer)
            SearchIndexRequest.create!(parent: @book, action: :index_item)
          end
          if fresh.any?
            @held = fresh.map { |bc| bc.country.name }
            return decide_held
          end

          @book.book_countries.reset
          @book.countries.reset
          finish("filled", applied: true, replaced: replaced)
        end

        def finish(reason, applied: false, raw: nil, replaced: [])
          Result.new(success?: true, errors: [], data: {
            applied: applied, reason: reason, country: @answer&.name, raw: raw,
            held: @held || @dossier.record["real_countries"], replaced: replaced
          })
        end
      end
    end
  end
end
