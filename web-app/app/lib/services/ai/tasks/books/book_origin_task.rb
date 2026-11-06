module Services
  module Ai
    module Tasks
      module Books
        # Judges one book's national origin from an evidence dossier, with the
        # old site's nationality rules. The dossier is read-only context; the
        # caller (the origin service) decides what to do with the answer.
        class BookOriginTask < EnrichmentTask
          PROMPT_VERSION = 1
          WORLDCAT_PLACES = 5

          def initialize(parent:, dossier:, mode: :knowledge, provider: nil, model: nil)
            raise ArgumentError, "BookOriginTask does not support :sourced mode" if mode == :sourced

            @dossier = dossier
            super(parent: parent, mode: mode, provider: provider, model: model)
          end

          private

          attr_reader :dossier

          def system_message
            <<~SYSTEM_MESSAGE
              You decide the national origin of one book for a book catalog: the single country whose literature the book belongs to, given as one English nationality adjective such as "French", "Japanese" or "Brazilian".#{research_instruction}

              Rules, in order:
              1. Start from the original language the book was written in.
              2. Then the author's primary nationality at the time the book was first published.
              3. If the original language is a main language of the author's country, use that country.
              4. If they disagree, the country associated with the original language wins.
              5. For an author with several nationalities, use the one that matches the original language.
              6. If the author's nationality changed over time, use the one at the time of first publication.
              7. Use the book's setting or cultural context only when it agrees with the original language or the author's nationality.
              8. Never a mixed nationality such as "Chinese American". Choose one.
              9. Answer "Unknown" when you cannot determine a single nationality. It is better than a guess.
              10. Answer "Multiple" only when no single answer is defensible after every rule above.

              Evidence. The book's record and what outside sources say about it follow. Wikidata's country of origin and the Wikipedia infobox's country are strong evidence when they agree with the author and the language. Library publication places show where editions were printed, which is weak evidence: translations and foreign editions are published everywhere. An author marked as a placeholder is not a person: the book has no known author, so decide from the language and the sources. An author marked as a place name stands for a traditional or anonymous work from that place, and is strong evidence of origin.

              Examples:
              - "The Great Gatsby" by F. Scott Fitzgerald. Original language English; author American. Result: American.
              - "One Hundred Years of Solitude" by Gabriel García Márquez. Spanish; Colombian. Result: Colombian.
              - "Lolita" by Vladimir Nabokov. English; Russian-American. Result: American, because of the original language.
              - "The Blind Assassin" by Margaret Atwood. English; Canadian. Result: Canadian.
              - "Heart of Darkness" by Joseph Conrad. English; Polish-British. Result: British, from the original language and the author's adopted nationality.
              - "One Thousand and One Nights". Arabic and Persian; no single author. Result: Multiple.
              - "Ideas and Opinions" by Albert Einstein. Mostly German; German-Swiss-American. Result: German, from the original language and the author's nationality when he wrote it.
              - "Haroun and the Sea of Stories" by Salman Rushdie. English; British-Indian. Result: British, from the original language and the author's citizenship.

              Set "recognized" to false if you do not know this specific book. "original_language" is the language the book was written in, or null. "confidence" is high, medium or low for the nationality you give. "reason" is one short sentence naming the rule and the evidence that decided it. Output only the JSON object described by the schema.
            SYSTEM_MESSAGE
          end

          def research_instruction
            return "" unless research?

            " Use web search to verify every fact before reporting it; prefer publisher, library and encyclopedia sources. Report what the sources say, not what you remember."
          end

          def user_prompt
            record = dossier.record
            lines = ["Book: \"#{record["title"]}\""]
            lines << "Subtitle: #{record["subtitle"]}" if record["subtitle"].present?
            Array(record["authors"]).each { |author| lines << author_line(author) }
            if record["first_published_year"].present?
              lines << "First published (our record): #{::Services::Books::YearLabel.call(record["first_published_year"])}"
            end
            lines << "Original language (our record): #{record["original_language"]}" if record["original_language"].present?
            real = Array(record["real_countries"])
            lines << "Our current origin: #{real.join(", ")}" if real.any?
            lines.concat(book_facts_lines, wikidata_lines, wikipedia_lines, worldcat_lines)
            lines << ""
            lines << "Give the book's origin as JSON matching the schema."
            lines.join("\n")
          end

          def author_line(author)
            name = author["name"]
            case author["kind"]
            when "placeholder"
              "Author: none known (catalogued as \"#{name}\", a placeholder, not a person)"
            when "place"
              "Author: catalogued under the place name \"#{name}\" (origin signal: #{author["place_country"]})"
            else
              return "Editor: #{name}" if author["role"] == "editor"

              details = [life_years(author), Array(author["countries"]).sort.join(", ").presence].compact
              details.any? ? "Author: #{name} (#{details.join("; ")})" : "Author: #{name}"
            end
          end

          def life_years(author)
            birth = ::Services::Books::YearLabel.call(author["birth_year"])
            death = ::Services::Books::YearLabel.call(author["death_year"])
            if birth && death
              "#{birth}–#{death}"
            elsif birth
              "born #{birth}"
            elsif death
              "died #{death}"
            end
          end

          def book_facts_lines
            facts = dossier.book_facts
            return [] if facts.blank?

            parts = []
            parts << "original language #{facts["original_language"]}" if facts["original_language"].present?
            origin = Array(facts["origin_countries"]).reject(&:blank?)
            parts << "origin #{origin.join(", ")}" if origin.any?
            parts.any? ? ["Earlier AI facts: #{parts.join("; ")}"] : []
          end

          def wikidata_lines
            wd = dossier.wikidata
            return [] if wd.blank?

            line = "Wikidata: \"#{wd["label"]}\""
            line += " (#{wd["description"]})" if wd["description"].present?
            line += "; country of origin: #{wd["countries"].join(", ")}" if Array(wd["countries"]).any?
            line += "; language: #{wd["languages"].join(", ")}" if Array(wd["languages"]).any?
            line += "; published: #{wd["publication_years"].join(", ")}" if Array(wd["publication_years"]).any?
            [line]
          end

          def wikipedia_lines
            wp = dossier.wikipedia
            return [] if wp.blank?

            parts = []
            parts << "country #{wp["infobox_country"]}" if wp["infobox_country"].present?
            parts << "language #{wp["infobox_language"]}" if wp["infobox_language"].present?
            lines = []
            lines << "Wikipedia infobox: #{parts.join("; ")}" if parts.any?
            lines << "Wikipedia lead: #{wp["lead"]}" if wp["lead"].present?
            lines
          end

          def worldcat_lines
            wc = dossier.worldcat
            return [] if wc.blank?

            parts = []
            places = Array(wc["publication_places"]).first(WORLDCAT_PLACES)
            parts << "published in #{places.join(", ")}" if places.any?
            parts << "earliest edition #{wc["earliest_year"]}" if wc["earliest_year"].present?
            parts.any? ? ["Library records (WorldCat): #{parts.join("; ")}"] : []
          end

          def response_schema = ResponseSchema

          class ResponseSchema < OpenAI::BaseModel
            required :recognized, OpenAI::Boolean, doc: "false if you do not know this specific book"
            required :original_language, String, nil?: true, doc: "The language's English name, or null"
            required :nationality, String, doc: "One English nationality adjective, or Unknown, or Multiple"
            required :confidence, String, doc: "high, medium or low, for the nationality"
            required :reason, String, doc: "One short sentence: the rule and evidence that decided it"
          end
        end
      end
    end
  end
end
