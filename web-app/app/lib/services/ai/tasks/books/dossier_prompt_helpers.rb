module Services
  module Ai
    module Tasks
      module Books
        # Prompt pieces the dossier-reading book tasks share, so the author
        # labelling (placeholders and place names are not people) and the research
        # instruction have one source.
        module DossierPromptHelpers
          private

          def research_instruction
            return "" unless research?

            " Use web search to verify every fact before reporting it; prefer publisher, library and encyclopedia sources. Report what the sources say, not what you remember."
          end

          def author_line(author)
            name = author["name"]
            return "Editor: #{name}" if author["role"] == "editor"

            case author["kind"]
            when "placeholder"
              "Author: none known (catalogued as \"#{name}\", a placeholder, not a person)"
            when "place"
              "Author: catalogued under the place name \"#{name}\" (origin signal: #{author["place_country"]})"
            else
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

          # "Sources: ..." for research-backed book_facts, or no line.
          def citation_lines(facts)
            urls = Array(facts["citations"]).filter_map { |c| c.is_a?(Hash) ? (c["url"] || c[:url]) : c }.reject(&:blank?)
            urls.any? ? ["Sources: #{urls.join(", ")}"] : []
          end
        end
      end
    end
  end
end
