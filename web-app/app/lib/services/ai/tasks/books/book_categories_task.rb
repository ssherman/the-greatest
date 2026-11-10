module Services
  module Ai
    module Tasks
      module Books
        # Judges one book's genres, audience, subjects and locations from an
        # evidence dossier. Genres and the audience come back as ids from the
        # closed vocabulary the caller passes in; subjects and locations come back
        # as names for the Mapper to resolve. The dossier is read-only context;
        # the caller decides what to apply.
        class BookCategoriesTask < EnrichmentTask
          include DossierPromptHelpers

          PROMPT_VERSION = 1
          WORLDCAT_SUBJECTS = 25
          GOODREADS_SHELVES = 15

          def initialize(parent:, dossier:, vocabulary:, mode: :knowledge, provider: nil, model: nil)
            raise ArgumentError, "BookCategoriesTask does not support :sourced mode" if mode == :sourced

            @dossier = dossier
            # Fiction and Nonfiction are the book type, decided by book_type, never a listed genre.
            @vocabulary = vocabulary.reject { |category| category.genre? && ::Books::Book::BOOK_TYPE_CATEGORY_NAMES.include?(category.name) }
            super(parent: parent, mode: mode, provider: provider, model: model)
          end

          private

          attr_reader :dossier, :vocabulary

          def system_message
            <<~SYSTEM_MESSAGE
              You categorize one book for a book catalog, from the evidence given.#{research_instruction}

              Give:
              - "book_type": fiction, nonfiction, poetry, religious or unknown.
              - "genres": ids from the numbered genre list below, at most 5, most important first. Use only ids on the list. Never invent an id.
              - "audience": the id of one audience from the audience list, or null. Most books have none: there is no adult audience. Choose one only when the book is written for that readership.
              - "subjects": free-text names, at most 8, most important first. A subject is a browse page a reader would want this book on ("World War II", "Chess", "Slavery"). It is not a theme so broad that it describes most literary fiction, such as identity, love, family or human nature, unless the book is centrally about that.
              - "locations": free-text places, at most 5. Each is the most specific place the book is substantially set in; for nonfiction, the place the book is about. Never list every place the book mentions. Mark each "real" or "fictional" (an invented place such as Middle-earth or Yoknapatawpha County is fictional). Give "parent", the containing place ("France" for Paris, "United States" for Georgia the state), or null when there is none.
              - "unlisted_genres": at most 5 genre names the evidence uses (Wikidata, Wikipedia, WorldCat, Goodreads) that are not on the genre list, such as "Bildungsroman". This is a report only.

              Every genre, the audience, every subject and every location carries a "confidence" (high, medium or low) and an "evidence" note, a short phrase naming the dossier section that supports it (record, Wikidata, Wikipedia, WorldCat, Goodreads, current categories or your own knowledge). Give low confidence to a guess. Set "recognized" to false if you do not know this specific book, and give an overall "confidence" for the whole answer. Output only the JSON object described by the schema.

              Genres (id: name — definition):
              #{vocabulary_lines("genre")}

              Audiences (id: name — definition):
              #{vocabulary_lines("audience")}
            SYSTEM_MESSAGE
          end

          def vocabulary_lines(type)
            vocabulary.select { |category| category.category_type == type }.sort_by(&:name).map do |category|
              description = category.description.to_s.squish
              description.present? ? "#{category.id}: #{category.name} — #{description}" : "#{category.id}: #{category.name}"
            end.join("\n")
          end

          def user_prompt
            lines = record_lines
            lines.concat(book_facts_lines, wikidata_lines, wikipedia_lines, worldcat_lines, goodreads_lines)
            lines << ""
            lines << "Give the book's categories as JSON matching the schema."
            lines.join("\n")
          end

          def record_lines
            record = dossier.record
            lines = ["Book: \"#{record["title"]}\""]
            lines << "Subtitle: #{record["subtitle"]}" if record["subtitle"].present?
            Array(record["authors"]).each { |author| lines << author_line(author) }
            if record["first_published_year"].present?
              lines << "First published (our record): #{::Services::Books::YearLabel.call(record["first_published_year"])}"
            end
            lines << "Original language (our record): #{record["original_language"]}" if record["original_language"].present?
            lines << "Description (our record): #{record["description"]}" if record["description"].present?
            current = Array(record["categories"])
            if current.any?
              lines << "Categories the book holds now (source in brackets):"
              current.each do |entry|
                chain = Array(entry["ancestors"])
                lines << "- #{entry["type"]}: #{entry["name"]}#{" (under #{chain.join(" › ")})" if chain.any?} [#{entry["source"]}]"
              end
            end
            lines
          end

          def book_facts_lines
            facts = dossier.book_facts
            return [] if facts.blank?

            parts = []
            parts << "type #{facts["book_type"]}" if facts["book_type"].present?
            parts << "original language #{facts["original_language"]}" if facts["original_language"].present?
            lines = []
            if parts.any?
              lines << (dossier.research_backed? ? "Web-verified facts (from a web search for this book): #{parts.join("; ")}" : "Earlier AI facts: #{parts.join("; ")}")
            end
            if dossier.research_backed?
              lines.concat(citation_lines(facts))
              lines << "Description: #{facts["description"]}" if facts["description"].present?
            end
            lines
          end

          def wikidata_lines
            wd = dossier.wikidata
            return [] if wd.blank?

            line = "Wikidata: \"#{wd["label"]}\""
            line += " (#{wd["description"]})" if wd["description"].present?
            lines = [line]
            {"genres" => "genre", "main_subjects" => "main subject", "narrative_locations" => "narrative location",
             "set_in_periods" => "set in period", "forms" => "form"}.each do |key, label|
              lines << "Wikidata #{label}: #{wd[key].join(", ")}" if Array(wd[key]).any?
            end
            lines
          end

          def wikipedia_lines
            wp = dossier.wikipedia
            return [] if wp.blank?

            lines = []
            lines << "Wikipedia lead: #{wp["lead"]}" if wp["lead"].present?
            infobox = {"infobox_genre" => "genre", "infobox_subject" => "subject", "infobox_set_in" => "set in",
                       "infobox_country" => "country", "infobox_language" => "language"}.filter_map do |key, label|
              "#{label} #{wp[key]}" if wp[key].present?
            end
            lines << "Wikipedia infobox: #{infobox.join("; ")}" if infobox.any?
            lines << "Wikipedia plot: #{wp["plot"]}" if wp["plot"].present?
            lines
          end

          def worldcat_lines
            wc = dossier.worldcat
            return [] if wc.blank?

            lines = []
            genres = wc["mapped_genres"].to_h.sort_by { |name, count| [-count.to_i, name.to_s] }
              .map { |name, count| "#{name.to_s.sub(/\Agenre:/, "")} (#{count})" }
            lines << "Library records (WorldCat) mapped genres: #{genres.join(", ")}" if genres.any?
            subjects = Array(wc["subjects"]).first(WORLDCAT_SUBJECTS)
            lines << "Library records (WorldCat) subject headings: #{subjects.join("; ")}" if subjects.any?
            lines << "Library records (WorldCat) summary: #{wc["summary"]}" if wc["summary"].present?
            lines
          end

          def goodreads_lines
            shelves = Array(dossier.goodreads&.dig("genres")).first(GOODREADS_SHELVES)
            shelves.any? ? ["Goodreads shelves: #{shelves.join(", ")}"] : []
          end

          def response_schema = ResponseSchema

          class TypeFact < OpenAI::BaseModel
            required :value, String, doc: "fiction, nonfiction, poetry, religious or unknown"
            required :confidence, String, doc: "high, medium or low"
            required :evidence, String, doc: "Short note naming the dossier section"
          end

          class GenreFact < OpenAI::BaseModel
            required :id, Integer, doc: "A genre id from the list"
            required :confidence, String, doc: "high, medium or low"
            required :evidence, String, doc: "Short note naming the dossier section"
          end

          class AudienceFact < OpenAI::BaseModel
            required :id, Integer, nil?: true, doc: "An audience id from the list, or null for none"
            required :confidence, String, doc: "high, medium or low"
            required :evidence, String, doc: "Short note naming the dossier section"
          end

          class SubjectFact < OpenAI::BaseModel
            required :name, String, doc: "A browse-page topic, in English"
            required :confidence, String, doc: "high, medium or low"
            required :evidence, String, doc: "Short note naming the dossier section"
          end

          class LocationFact < OpenAI::BaseModel
            required :name, String, doc: "The most specific place, in English"
            required :kind, String, doc: "real or fictional"
            required :parent, String, nil?: true, doc: "The containing place, or null"
            required :confidence, String, doc: "high, medium or low"
            required :evidence, String, doc: "Short note naming the dossier section"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :recognized, OpenAI::Boolean, doc: "false if you do not know this specific book"
            required :confidence, String, doc: "high, medium or low, overall"
            required :book_type, TypeFact
            required :genres, OpenAI::ArrayOf[GenreFact], doc: "At most 5"
            required :audience, AudienceFact
            required :subjects, OpenAI::ArrayOf[SubjectFact], doc: "At most 8, most important first"
            required :locations, OpenAI::ArrayOf[LocationFact], doc: "At most 5"
            required :unlisted_genres, OpenAI::ArrayOf[String], doc: "At most 5 genre names from the evidence that are not on the list"
          end
        end
      end
    end
  end
end
