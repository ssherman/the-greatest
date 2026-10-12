# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        # Decides what each books location category should become (spec §2, §3.1, §4.2).
        class LocationTask < BaseCleanupTask
          VERDICTS = %w[real_place fictional_place not_a_place junk].freeze
          PLACE_KINDS = %w[continent region country subdivision city site historical_state fictional global].freeze

          private

          def noun = "locations"

          def system_message
            <<~SYSTEM
              You are cleaning up the "setting" locations of a book catalog. Each location is a category books are linked to because they are set there.

              For each location you get its current name, how many books carry it, and a few of those books. Decide:
              - verdict: "real_place" (a real place, current or historical), "fictional_place" (an invented place), "not_a_place" (a theme or topic stored as a location by mistake, like "Love"), or "junk" (meaningless, truncated, or not a name).
              - canonical_name: the name it should have, following the naming rules. When merge_into is set, the merge target's name.
              - merge_into: when it is the same place as a DIFFERENT known location (never its own name), that location's exact name; otherwise null.
              - parent_chain: for every real or fictional place, unless merge_into is set: the places containing it from the immediate parent up to a root, using known names when they exist. Empty only for a root.
              - place_kind: continent, region, country, subdivision, city, site, historical_state, fictional, or global; null for not_a_place and junk.
              - retype_to: "subject" when the verdict is not_a_place and the name is a real subject; otherwise null.
              - ambiguous: true when the sample books show the name used for two different places.
              - reason: one short sentence.
              Judge by the sample books when the name alone is unclear.

              Naming rules:
              - The common English name, current if the place still exists ("Kolkata", not "Calcutta"; "Gdańsk", not "Danzig"). Historical states keep their historical name ("Soviet Union", "Roman Empire").
              - No containing place in the name: "Paris", not "Paris, France".
              - Title Case, Chicago style (minor words lowercase unless first); "and" not "&"; straight apostrophes and hyphens; no trailing punctuation, but keep a place's established capitalization (Rio de Janeiro, Côte d'Ivoire).
              - Add a parenthetical qualifier only when the known list already contains a different place with the same bare name ("Georgia" the country vs "Georgia (U.S. state)"); never add a qualifier otherwise.

              Hierarchy rules:
              - Roots: Africa, Antarctica, Asia, Europe, North America, Oceania, South America, Fictional Location, regions spanning continents (Middle East, Arctic), and global places (Outer Space, Atlantic Ocean, Pacific Ocean, Indian Ocean).
              - A country's parent is always its continent. Named regions inside one continent (Scandinavia, Balkans, Caribbean) sit under that continent, but countries never go under them.
              - A transcontinental country goes under the continent holding most of its population (Russia: Europe; Turkey: Asia).
              - Places spanning several countries go under their nearest shared region or continent (Alps: Europe).
              - Historical cities and sites go under the modern country they lie in (Troy: Turkey). Historical states and empires go under their continent.
              - A city and an administrative unit covering the same place are one place (Berlin and "Berlin (state)", Tokyo and "Tokyo Metropolis", Washington, D.C. and "District of Columbia", London and "Greater London", Saint Petersburg and "Saint Petersburg (federal city)"). The unit merges into the city and never appears in the city's parent_chain.
              - Invented worlds and places in them go under Fictional Location (Middle-earth). An invented town inside the real world gets its real parent.

              The known list includes the names under review. An entry's own current name in that list is the entry itself, not a different place.

              #{known_names_block}
            SYSTEM
          end

          def response_schema = ResponseSchema

          def normalize(raw)
            verdict = string(raw, :verdict)
            return nil unless VERDICTS.include?(verdict)

            kind = string(raw, :place_kind)
            {
              key: string(raw, :key),
              verdict: verdict,
              canonical_name: string(raw, :canonical_name),
              merge_into: string(raw, :merge_into).presence,
              parent_chain: Array(value(raw, :parent_chain)).map { |name| name.to_s.strip }.reject(&:blank?),
              place_kind: PLACE_KINDS.include?(kind) ? kind : nil,
              retype_to: (string(raw, :retype_to) == "subject") ? "subject" : nil,
              ambiguous: value(raw, :ambiguous) == true,
              reason: string(raw, :reason)
            }
          end

          class LocationResult < OpenAI::BaseModel
            required :key, String, doc: "The location's number from the list"
            required :verdict, String, doc: "real_place, fictional_place, not_a_place or junk"
            required :canonical_name, String, doc: "The name it should have"
            required :merge_into, String, nil?: true, doc: "Exact name of the known location it duplicates, or null"
            required :parent_chain, OpenAI::ArrayOf[String], doc: "Containing places, immediate parent first, root last; empty for a root"
            required :place_kind, String, nil?: true, doc: "continent, region, country, subdivision, city, site, historical_state, fictional or global"
            required :retype_to, String, nil?: true, doc: "subject, or null"
            required :ambiguous, OpenAI::Boolean, doc: "true if the books show two different places under this name"
            required :reason, String, doc: "One short sentence"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :results, OpenAI::ArrayOf[LocationResult], doc: "One result per location"
          end
        end
      end
    end
  end
end
