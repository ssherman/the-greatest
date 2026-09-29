# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Which VIAF person is this author, or none (spec §8). Runs after a
      # Wikidata miss. Two stages, and the first that decides ends the run:
      # the VIAF id the author already holds, then one AutoSuggest on the
      # name. AutoSuggest answers with several rows per cluster (a plain
      # heading, one with dates, one with a description, translations), so
      # rows are grouped by VIAF id into one candidate each. A rule decides
      # when exactly one person has a heading equal to our name and a birth
      # year agreeing with ours; otherwise at most three clusters are read and
      # SelectExternalRecordTask chooses. Every run records one MatchDecision.
      # Applies nothing; Viaf::Client stores every cluster it reads.
      class ResolveViaf
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        # suggestions: this cluster's AutoSuggest rows. unavailable: why its
        # cluster could not be read.
        Candidate = Struct.new(:viaf_id, :sources, :suggestions, :person, :matching_titles, :unavailable, keyword_init: true)
        Verdict = Struct.new(:outcome, :candidate, :decided_by, :confidence, :reason, :ai_chat, keyword_init: true)

        VIAF = "books_author_viaf"
        MAX_FETCHED = 3
        YEAR_TOLERANCE = 1
        GUIDANCE = "Our author wrote the books listed. Select a record only when the evidence ties that person to writing " \
          "these books: a matching work, or life dates that agree together with an occupation or nationality that fits. " \
          "A person who merely shares the name is someone else. VIAF often holds one person as two records; when " \
          "records describe the same person, select the one with the most contributing libraries, and do not treat " \
          "that as a tie."

        def self.call(author:, refresh: false, client: nil)
          new(author: author, refresh: refresh, client: client).call
        end

        def initialize(author:, refresh:, client:)
          @author = author
          @refresh = refresh
          @client = client || ::Viaf::Client.new
          @profile = AuthorProfile.new(author)
          @candidates = {}
          @sources_failed = []
          @shown = nil
        end

        def call
          record(held_stage || search_stage)
        end

        private

        attr_reader :author

        # ---- stages ---------------------------------------------------------

        def held_stage
          ids = identifier_values(VIAF)
          return nil if ids.empty?

          ids.each { |id| fetch(add(id, "held_id")) }
          held = persons.find { |candidate| candidate.sources.include?("held_id") && corroborated?(candidate) }
          return nil unless held

          Verdict.new(outcome: :matched, candidate: held, decided_by: :identifier, confidence: :certain,
            reason: "The VIAF id the author holds, #{held.viaf_id}, is a person whose name and years agree.")
        end

        def search_stage
          @client.suggest(author.name).each { |suggestion| add(suggestion.viaf_id, "name_search").suggestions << suggestion }
          pool = persons
          if pool.empty?
            return Verdict.new(outcome: :unmatched, candidate: nil, decided_by: :rule, confidence: :high,
              reason: "No person among #{@candidates.size} VIAF candidates.")
          end

          rule_verdict(pool) || ask_ai(pool)
        end

        # Exactly one person with a heading equal to our name and a birth year
        # agreeing with ours. Its cluster is then read and must still agree.
        def rule_verdict(pool)
          named = pool.select { |candidate| heading_matches?(candidate) }
          return nil unless named.size == 1 && suggested_birth_agrees?(named.first)

          only = fetch(named.first)
          return nil unless person?(only) && !year_conflict?(only)

          Verdict.new(outcome: :matched, candidate: only, decided_by: :rule, confidence: :high,
            reason: "The only VIAF person named #{author.name}, born #{author.birth_year} as ours.")
        end

        def ask_ai(pool)
          shown = ordered(pool).first(MAX_FETCHED).each { |candidate| fetch(candidate) }.select { |candidate| person?(candidate) }
          if shown.empty?
            return Verdict.new(outcome: :unmatched, candidate: nil, decided_by: :rule, confidence: :high,
              reason: "None of the suggested VIAF clusters could be read as a person.")
          end

          attach_titles(shown)
          select_with_ai(shown)
        end

        def select_with_ai(shown)
          # Remembered so `record` can number stored candidates the same way
          # the AI saw them: `shown` is ordered from AutoSuggest-only evidence
          # (agency counts, headings) before any cluster is fetched, while a
          # plain `ordered(persons)` re-sorts afterward using the fetched
          # clusters' own agency counts. Without this, "record 1" in the AI's
          # reasoning or `same_entity_groups` could name a different row than
          # candidate 1 on the audit page.
          @shown = shown
          result = ::Services::Ai::Tasks::Matching::SelectExternalRecordTask.new(
            parent: author, source_name: "VIAF", entity_noun: "author",
            query_line: @profile.line, candidate_lines: shown.map { |candidate| describe(candidate) }, guidance: GUIDANCE
          ).call
          return ai_failed(result.error, result.ai_chat) unless result.success?

          index = result.data[:selected_index]
          chosen = index.positive? ? shown[index - 1] : nil
          Verdict.new(outcome: chosen ? :matched : :unmatched, candidate: chosen, decided_by: :ai,
            confidence: result.data[:confidence].to_sym, reason: result.data[:reasoning].to_s, ai_chat: result.ai_chat)
        rescue => e
          ai_failed("#{e.class}: #{e.message}", nil)
        end

        def ai_failed(message, chat)
          Verdict.new(outcome: :failed, candidate: nil, decided_by: :fallback, confidence: :low,
            reason: "AI selection failed: #{message}", ai_chat: chat)
        end

        # ---- gathering ------------------------------------------------------

        def add(viaf_id, source)
          candidate = (@candidates[viaf_id.to_s] ||= Candidate.new(viaf_id: viaf_id.to_s, sources: [], suggestions: [], matching_titles: []))
          candidate.sources |= [source]
          candidate
        end

        # Reads the cluster once. A cluster VIAF no longer serves (gone or
        # withdrawn) drops out; any other error ends the run.
        def fetch(candidate)
          return candidate if candidate.person || candidate.unavailable

          candidate.person = @client.cluster(candidate.viaf_id, refresh: @refresh)
          candidate
        rescue ::Viaf::Exceptions::NotFoundError, ::Viaf::Exceptions::AbandonedRecordError => e
          candidate.unavailable = e.class.name.demodulize
          @sources_failed |= ["viaf_cluster"]
          candidate
        end

        def persons = @candidates.values.select { |candidate| person?(candidate) }

        # A read cluster decides; before that, AutoSuggest's name type.
        def person?(candidate)
          return false if candidate.unavailable
          return candidate.person.kind == :person if candidate.person

          candidate.suggestions.any? { |suggestion| suggestion.kind == :person }
        end

        def attach_titles(shown)
          ours = @profile.titles.map { |title| title_key(title) }.to_set
          shown.each do |candidate|
            candidate.matching_titles = candidate.person.titles.select { |title| ours.include?(title_key(title)) }
              .uniq { |title| title_key(title) }
          end
        end

        # ---- judgements -----------------------------------------------------

        def corroborated?(candidate) = names_agree?(candidate) && !year_conflict?(candidate)

        def names_agree?(candidate)
          person = candidate.person
          names = person.main_headings.map { |heading| heading["name"] } + person.names
          names.any? { |name| author_tokens.include?(ViafNames.tokens(name)) }
        end

        def heading_matches?(candidate)
          candidate.suggestions.any? { |suggestion| author_tokens.include?(ViafNames.tokens(suggestion.term)) }
        end

        def author_tokens
          @author_tokens ||= @profile.names.map { |name| ViafNames.tokens(name) }.reject(&:empty?).to_set
        end

        def suggested_birth_agrees?(candidate)
          theirs = candidate.suggestions.filter_map(&:birth_year).first
          author.birth_year.present? && theirs.present? && (author.birth_year - theirs).abs <= YEAR_TOLERANCE
        end

        def year_conflict?(candidate)
          birth, death = candidate_years(candidate)
          years_conflict?(author.birth_year, birth) || years_conflict?(author.death_year, death)
        end

        def years_conflict?(ours, theirs)
          ours.present? && theirs.present? && (ours - theirs).abs > YEAR_TOLERANCE
        end

        # From the cluster once read (life dates only, never a flourished
        # span), else from the AutoSuggest rows.
        def candidate_years(candidate)
          person = candidate.person
          return [nil, nil] if person && !person.lived?
          return [person.birth_year, person.death_year] if person

          [candidate.suggestions.filter_map(&:birth_year).first, candidate.suggestions.filter_map(&:death_year).first]
        end

        def agency_count(candidate)
          return candidate.person.agency_count if candidate.person

          candidate.suggestions.flat_map { |suggestion| suggestion.source_ids.keys }.uniq.size
        end

        # Held ids first, then a heading equal to our name, no year conflict,
        # the most contributing libraries, and AutoSuggest's own order.
        def ordered(pool)
          pool.each_with_index.sort_by do |candidate, index|
            [candidate.sources.include?("held_id") ? 0 : 1, heading_matches?(candidate) ? 0 : 1,
              year_conflict?(candidate) ? 1 : 0, -agency_count(candidate), index]
          end.map(&:first)
        end

        # The AI's own order first (see `select_with_ai`), then any other
        # persons in `ordered`'s usual order, so the stored candidate numbers
        # match what the AI was shown. When the AI was never asked, `@shown`
        # is nil and this is plain `ordered(persons)`.
        def ordered_persons(persons)
          return ordered(persons) unless @shown

          @shown + (ordered(persons) - @shown)
        end

        # ---- our side -------------------------------------------------------

        def identifier_values(type)
          author.identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end

        # The main title, case and diacritics folded: VIAF titles carry
        # subtitles ("Forget me not : a novel").
        def title_key(text)
          main = text.to_s.sub(%r{\s*[:/;].*\z}m, "").presence || text.to_s
          ::Services::Text::QuoteNormalizer.call(main).to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.squish
        end

        # ---- describing -----------------------------------------------------

        def describe(candidate)
          person = candidate.person
          parts = [display_name(candidate)]
          span = lifespan(person)
          parts << span if span
          parts << "nationality: #{person.country_codes.join(", ")}" if person.country_codes.any?
          parts << "occupations: #{person.occupation.first(5).join(", ")}" if person.occupation.any?
          parts << "works matching ours: #{candidate.matching_titles.first(5).join("; ")}" if candidate.matching_titles.any?
          others = person.titles - candidate.matching_titles
          parts << "other works: #{others.first(5).join("; ")}" if others.any?
          parts << "#{person.agency_count} contributing libraries"
          parts << "year conflict" if year_conflict?(candidate)
          parts << "viaf #{candidate.viaf_id}"
          parts.join(" | ")
        end

        # The first library heading, in natural order when it is entered
        # under a surname ("Willingham, Stacy" is Stacy Willingham); a
        # forename heading ("Marcus Aurelius, Emperor of Rome") is shown as
        # written, since inverting it would be wrong. Falls back to
        # AutoSuggest's form, then the id. The Wikidata-built heading is a
        # label and a description, not a name.
        def display_name(candidate)
          heading = candidate.person&.main_headings&.find { |entry| entry["source"] != "WKP" }
          if heading
            name = heading["name"]
            return (heading["surname_first"] == true) ? (ViafNames.natural(name) || name) : name
          end

          candidate.suggestions.first&.display_form || candidate.viaf_id
        end

        def lifespan(person)
          span = AuthorProfile.lifespan(person.birth_year, person.death_year)
          return nil if span.nil?

          person.lived? ? span : "active #{span}"
        end

        # ---- recording ------------------------------------------------------

        def record(verdict)
          ordered_all = ordered_persons(persons) + (@candidates.values - persons)
          confidence = verdict.confidence
          confidence = :medium if confidence == :high && @sources_failed.any?
          decision = ::MatchDecision.create!(
            finder: self.class.name,
            subject: author,
            record: nil,
            outcome: (verdict.outcome == :matched) ? :matched : :unmatched,
            confidence: confidence,
            decided_by: verdict.decided_by,
            verify: false,
            query: author_snapshot,
            candidates: ordered_all.map { |candidate| snapshot(candidate) },
            selected_index: verdict.candidate && (ordered_all.index(verdict.candidate) + 1),
            reason: verdict.reason,
            ai_chat: verdict.ai_chat,
            sources_failed: @sources_failed,
            needs_review: verdict.decided_by == :fallback || %i[medium low].include?(confidence)
          )
          Result.new(
            success?: true,
            data: {outcome: verdict.outcome, person: verdict.candidate&.person, decision: decision, reason: verdict.reason},
            errors: []
          )
        end

        def author_snapshot
          {
            "name" => author.name,
            "alternate_names" => Array(author.alternate_names).first(10),
            "birth_year" => author.birth_year,
            "death_year" => author.death_year,
            "viaf" => identifier_values(VIAF),
            "titles" => @profile.titles.first(10)
          }
        end

        def snapshot(candidate)
          person = candidate.person
          birth, death = candidate_years(candidate)
          evidence = {
            "external_title" => display_name(candidate),
            "external_year" => birth,
            "headings" => candidate.suggestions.map(&:term).uniq.first(5),
            "birth_year" => birth,
            "death_year" => death,
            "agency_count" => agency_count(candidate),
            "year_conflict" => year_conflict?(candidate)
          }
          if person
            evidence.merge!(
              "date_type" => person.date_type,
              "nationality" => person.country_codes,
              "occupations" => person.occupation.first(5),
              "matching_titles" => candidate.matching_titles.first(10),
              "other_titles" => (person.titles - candidate.matching_titles).first(5),
              "wikidata_qid" => person.wikidata_qid
            )
          end
          evidence["unavailable"] = candidate.unavailable if candidate.unavailable
          evidence["dropped"] = "not a person" unless candidate.unavailable || person?(candidate)
          {
            "record_type" => nil, "record_id" => nil,
            "external_source" => "viaf", "external_key" => candidate.viaf_id,
            "sources" => candidate.sources, "scores" => {},
            "evidence" => evidence.compact
          }
        end
      end
    end
  end
end
