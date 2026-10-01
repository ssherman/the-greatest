module Services
  module Ai
    module Tasks
      module Books
        # Facts and a description for one Books::Author in a single call
        # (spec §9), grounded in what we hold and in the records the author
        # steps matched (Services::Books::Authors::MatchedRecords): the
        # Wikidata item, its English Wikipedia lead, and the VIAF cluster.
        # Applied by Services::Books::Authors::ApplyAuthorFacts. Inside this
        # module `Books` is Services::Ai::Tasks::Books, so model and service
        # constants are root-anchored.
        class AuthorFactsTask < EnrichmentTask
          BOOK_LIMIT = 10
          WORK_LIMIT = 10
          LIST_LIMIT = 5
          # A runaway guard, not a summary: a lead is a few paragraphs.
          LEAD_LIMIT = 8_000

          def initialize(parent:, records:, mode: :knowledge, provider: nil, model: nil)
            @records = records
            super(parent: parent, mode: mode, provider: provider, model: model)
          end

          private

          attr_reader :records

          def system_message
            <<~SYSTEM_MESSAGE
              You are a bibliographic researcher for a book catalog. You report facts about one author and write one short description of them.#{research_instruction}

              Facts. For every fact give a value and a confidence of high, medium or low. Use null (or an empty list) when you do not know; never guess. Set "recognized" to false if neither the sources given nor your own knowledge tell you who this specific author is, and give an overall "confidence" for how well you know them. The Wikidata, library and Wikipedia sources below were matched to this author; prefer them to memory. When no source is given, the name may belong to several people: describe only the person who wrote the books listed. birth_year and death_year are years of the Common Era, and a year before the Common Era is reported as null; death_year is null for a living person. gender is male, female or non_binary. nationalities are English nationality adjectives such as "French" or "Japanese", one for each country the author was a citizen of.

              Description rules.
              - One paragraph, 60 to 110 words, sentences of varied length.
              - Say who the author is or was, when and where they lived and worked, what they write or wrote, and their best-known works named plainly. Name a literary movement only if one clearly applies.
              - At most one major prize, stated plainly, such as "won the 1954 Nobel Prize in Literature". No other awards.
              - Do not open with the author's name; the page shows it.
              - For a living author, nothing about their personal life beyond what the sources state, and never a death year.
              - No em dashes or double hyphens, no semicolons, no lists, no emoji, no quotation marks around titles.
              - No marketing or judgment: no acclaimed, bestselling, masterpiece, beloved, celebrated, legendary, one of the greatest, must-read, no sales figures.
              - No meta narration such as "This author" or "Readers will". Open on the person.
              - Plain words. Do not use: delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, navigate, resonate, profound, haunting, luminous, or "explores themes of".
              - No "not X but Y" constructions. No ornamental triads of adjectives.
              - Write in your own words and your own sentence structure. Use the Wikipedia text for facts only; never reuse its phrases.
              - Only what you are sure of. Say less rather than guess. If you do not know who this author is well enough to describe them, set description to null.
              - No citations, URLs, footnotes, or bracketed references inside any text field.

              Output only the JSON object described by the schema.
            SYSTEM_MESSAGE
          end

          def research_instruction
            return "" unless research?

            " Use web search to verify every fact before reporting it; prefer library, publisher and encyclopedia sources. Report what the sources say, not what you remember."
          end

          def user_prompt
            lines = ["Author: #{parent.name}"]
            alternates = Array(parent.alternate_names).first(10)
            lines << "Also known as: #{alternates.join("; ")}" if alternates.any?
            stored = stored_facts
            lines << "Already on record: #{stored.join("; ")}" if stored.any?
            lines.concat(book_lines)
            lines.concat(source_lines)
            lines << ""
            lines << "Report the facts and write the description as JSON matching the schema."
            lines.join("\n")
          end

          def stored_facts
            facts = []
            facts << "born #{parent.birth_year}" if parent.birth_year
            facts << "died #{parent.death_year}" if parent.death_year
            facts << "gender #{parent.gender.tr("_", "-")}" if parent.gender.present? && parent.gender != "unspecified"
            countries = parent.countries.map(&:name).sort
            facts << "nationality #{countries.join(", ")}" if countries.any?
            facts
          end

          def book_lines
            books = ::Services::Books::Authors::AuthorProfile.new(parent).ranked_books(BOOK_LIMIT)
            return [] if books.empty?

            ["Books by this author in our catalog, best known first:"] +
              books.map { |title, year| year ? "- #{title} (#{year})" : "- #{title}" }
          end

          def source_lines
            lines = []
            wikidata = records.wikidata && describe_wikidata(records.wikidata.evidence)
            lines << "Wikidata: #{wikidata}" if wikidata.present?
            viaf = records.viaf && describe_viaf(records.viaf.evidence)
            lines << "Library authority record (VIAF): #{viaf}" if viaf.present?
            extract = records.lead ? records.lead.extract.to_s.strip : ""
            if extract.present?
              lines << ""
              lines << "Wikipedia lead, for facts only; do not reuse its wording:"
              lines << extract.first(LEAD_LIMIT)
            end
            if records.wikidata.nil? && records.viaf.nil?
              lines << "No Wikidata, library or Wikipedia record was matched to this author."
            end
            lines
          end

          def describe_wikidata(evidence)
            parts = []
            parts << evidence["description"] if evidence["description"].present?
            span = ::Services::Books::Authors::AuthorProfile.lifespan(evidence["birth_year"], evidence["death_year"])
            parts << span if span
            listed(parts, "occupations", evidence["occupations"])
            listed(parts, "citizenship", evidence["citizenships"])
            works = works(evidence)
            parts << "notable works: #{works.join("; ")}" if works.any?
            parts.join(" | ")
          end

          def describe_viaf(evidence)
            parts = []
            headings = Array(evidence["headings"]).presence || Array(evidence["external_title"])
            parts << "headings: #{headings.first(LIST_LIMIT).join("; ")}" if headings.any?
            span = ::Services::Books::Authors::AuthorProfile.lifespan(evidence["birth_year"], evidence["death_year"])
            if span
              lived = evidence["date_type"].blank? || evidence["date_type"].to_s.casecmp?("lived")
              parts << (lived ? span : "active #{span}")
            end
            listed(parts, "nationality", evidence["nationality"])
            listed(parts, "occupations", evidence["occupations"])
            works = works(evidence)
            parts << "works: #{works.join("; ")}" if works.any?
            parts << "#{evidence["agency_count"]} contributing libraries" if evidence["agency_count"]
            parts.join(" | ")
          end

          def listed(parts, label, values)
            values = Array(values).compact_blank.first(LIST_LIMIT)
            parts << "#{label}: #{values.join(", ")}" if values.any?
          end

          def works(evidence)
            (Array(evidence["matching_titles"]) + Array(evidence["other_titles"])).compact_blank.uniq.first(WORK_LIMIT)
          end

          def response_schema = ResponseSchema

          class ResponseSchema < OpenAI::BaseModel
            required :recognized, OpenAI::Boolean, doc: "false if neither the sources nor your knowledge tell you who this author is"
            required :confidence, String, doc: "high, medium or low: how well you know this specific author"
            required :birth_year, EnrichmentTask::IntegerFact
            required :death_year, EnrichmentTask::IntegerFact, doc: "null for a living person"
            required :gender, EnrichmentTask::StringFact, doc: "male, female or non_binary"
            required :nationalities, EnrichmentTask::StringListFact, doc: "English nationality adjectives"
            required :description, EnrichmentTask::StringFact, doc: "One paragraph following the rules"
          end
        end
      end
    end
  end
end
