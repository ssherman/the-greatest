# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Which Wikidata person is this author, or none (spec §5).
      #
      # Candidates come in three stages, and a stage whose rule decides ends
      # the run: the Wikidata id the author already holds (rule 1), one
      # haswbstatement query over its other identifiers (rule 2), then a name
      # search on the name and up to two alternate names. Only persons
      # (human, pseudonym, collective pseudonym) survive; their works are
      # compared with our titles; rule 3 or the AI decides. Every run records
      # one MatchDecision and stores the chosen item in external_records.
      # Applies nothing.
      class ResolveWikidata
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        Candidate = Struct.new(:entity, :sources, :titles, :matching_titles, keyword_init: true)
        Verdict = Struct.new(:outcome, :candidate, :decided_by, :confidence, :reason, :ai_chat, keyword_init: true)

        ALTERNATE_SEARCHES = 2
        MAX_AI_CANDIDATES = 6
        YEAR_TOLERANCE = 1
        # Hyphen-minus, hyphen, non-breaking hyphen.
        HYPHENS = /[-‐‑]/
        QID = "books_author_wikidata_qid"
        BRIDGE_PROPERTIES = {
          "books_author_openlibrary_id" => "P648",
          "books_author_viaf" => "P214",
          "books_author_isni" => "P213",
          "books_author_lcnaf" => "P244"
        }.freeze
        SHARED_IDENTIFIER_KINDS = {
          "openlibrary" => "books_author_openlibrary_id",
          "viaf" => "books_author_viaf",
          "isni" => "books_author_isni",
          "lcnaf" => "books_author_lcnaf"
        }.freeze
        GUIDANCE = "Our author wrote the books listed. Select a record only when the evidence ties that person to writing " \
          "these books: a matching work, a shared identifier, or life dates that agree together with a description or " \
          "occupation that shows a writer. A person who merely shares the name, or shares the name and the dates but " \
          "is not a writer, is someone else. A pseudonym or pen-name record counts when its works match."

        def self.call(author:, refresh: false, client: nil)
          new(author: author, refresh: refresh, client: client).call
        end

        def initialize(author:, refresh:, client:)
          @author = author
          @refresh = refresh
          @client = client || ::Wikidata::Client.new
          @profile = AuthorProfile.new(author)
          @candidates = {}
          @loaded = {}
          @raw = {}
          @redirects = {}
          @sources_failed = []
          @rejected = RejectedRecords.new(author)
        end

        def call
          record(held_stage || bridge_stage || search_stage)
        end

        private

        attr_reader :author

        # ---- stages ---------------------------------------------------------

        def held_stage
          ids = identifier_values(QID)
          return nil if ids.empty?

          gather(ids, "held_id")
          held = persons.find { |candidate| candidate.sources.include?("held_id") && corroborated?(candidate) }
          return nil unless held

          Verdict.new(outcome: :matched, candidate: held, decided_by: :identifier, confidence: :certain,
            reason: "The Wikidata id the author holds, #{held.entity.id}, is a person whose name and years agree.")
        end

        def bridge_stage
          pairs = bridge_pairs
          return nil if pairs.empty?

          gather(@client.by_statements(pairs), "id_bridge")
          bridged = persons.select { |candidate| candidate.sources.include?("id_bridge") }
          return nil unless bridged.size == 1 && corroborated?(bridged.first)

          shared = shared_identifiers(bridged.first).map { |identifier| identifier["type"] }.uniq
          Verdict.new(outcome: :matched, candidate: bridged.first, decided_by: :identifier, confidence: :certain,
            reason: "The only person carrying the author's #{shared.join(", ").presence || "identifiers"}, with agreeing name and years.")
        end

        def search_stage
          # One search per name, then every hit's entity in one call.
          gather(search_names.flat_map { |name| @client.search(name).map { |hit| hit["id"] } }, "name_search")
          if persons.empty?
            return Verdict.new(outcome: :unmatched, candidate: nil, decided_by: :rule, confidence: :high,
              reason: "No person among #{@candidates.size} Wikidata candidates.")
          end

          attach_titles
          named = persons.select { |candidate| names_agree?(candidate) && !year_conflict?(candidate) }
          if named.size == 1 && named.first.matching_titles.any?
            only = named.first
            if persons.none? { |candidate| !candidate.equal?(only) && id_hit?(candidate) }
              return Verdict.new(outcome: :matched, candidate: only, decided_by: :rule, confidence: :high,
                reason: "The only person named #{author.name} with agreeing years, sharing #{only.matching_titles.size} title(s) with our books.")
            end
          end

          ask_ai
        end

        def ask_ai
          shown = ordered_persons.first(MAX_AI_CANDIDATES)
          lines = shown.map { |candidate| describe(candidate) }
          result = ::Services::Ai::Tasks::Matching::SelectExternalRecordTask.new(
            parent: author, source_name: "Wikidata", entity_noun: "author",
            query_line: @profile.line, candidate_lines: lines, guidance: GUIDANCE
          ).call
          return ai_failed(result.error, result.ai_chat) unless result.success?

          index = result.data[:selected_index]
          chosen = index.positive? ? shown[index - 1] : nil
          Verdict.new(outcome: chosen ? :matched : :unmatched, candidate: chosen, decided_by: :ai,
            confidence: result.data[:confidence].to_sym, reason: result.data[:reasoning].to_s, ai_chat: result.ai_chat)
        rescue ::Wikimedia::Exceptions::RateLimited
          raise
        rescue => e
          ai_failed("#{e.class}: #{e.message}", nil)
        end

        def ai_failed(message, chat)
          Verdict.new(outcome: :failed, candidate: nil, decided_by: :fallback, confidence: :low,
            reason: "AI selection failed: #{message}", ai_chat: chat)
        end

        # ---- gathering ------------------------------------------------------

        # Adds the entities for these ids as candidates reached by `source`.
        # A merged item arrives under the surviving id, so two requested ids
        # can land on one candidate. A record rejected for this author (spec
        # §5.1, §12) is never fetched, and one reached through an old id is
        # dropped.
        def gather(ids, source)
          wanted = Array(ids).map(&:to_s).uniq.reject { |id| @rejected.include?(:wikidata, id) }
          load_entities(wanted).each do |entity|
            next if @rejected.include?(:wikidata, entity.id)

            candidate = (@candidates[entity.id] ||= Candidate.new(entity: entity, sources: [], titles: [], matching_titles: []))
            candidate.sources |= [source]
          end
        end

        def load_entities(ids)
          wanted = ids.reject { |id| @loaded.key?(id) }
          stored = @refresh ? {} : ::Services::ExternalRecords::Store.find_all(
            source: :wikidata, source_ids: wanted, schema_version: ::Wikidata::Distiller::SCHEMA_VERSION
          )
          stored.each { |id, row| @loaded[id] = ::Wikidata::Entity.from_payload(row.payload) }
          fetch = wanted - stored.keys
          @client.entities(fetch).each do |requested, data|
            payload = ::Wikidata::Distiller.call(data)
            @raw[payload["id"]] = JSON.generate(data)
            @redirects[requested] = payload["id"] if requested != payload["id"]
            @loaded[requested] = ::Wikidata::Entity.from_payload(payload)
          end
          ids.filter_map { |id| @loaded[id] }
        end

        def persons = @candidates.values.select { |candidate| candidate.entity.person? }

        def attach_titles
          works = begin
            @client.works(persons.map { |candidate| candidate.entity.id })
          rescue ::Wikimedia::Exceptions::Error => e
            Rails.logger.warn("#{self.class.name}: works query failed for author #{author.id}: #{e.class}: #{e.message}")
            @sources_failed << "wikidata_works"
            {}
          end
          ours = @profile.titles.map { |title| title_key(title) }.to_set
          persons.each do |candidate|
            candidate.titles = works.fetch(candidate.entity.id, [])
            candidate.matching_titles = candidate.titles.select { |title| ours.include?(title_key(title)) }.uniq { |title| title_key(title) }
          end
        end

        # Evidence labels only: a failure leaves them out, never the run, and
        # is recorded in sources_failed.
        def labels
          @labels ||= begin
            ids = persons.flat_map { |candidate| candidate.entity.occupation_ids + candidate.entity.citizenship_ids }.uniq
            ids.empty? ? {} : @client.labels(ids)
          rescue ::Wikimedia::Exceptions::Error => e
            Rails.logger.warn("#{self.class.name}: labels failed for author #{author.id}: #{e.class}: #{e.message}")
            @sources_failed << "wikidata_labels"
            {}
          end
        end

        # ---- judgements -----------------------------------------------------

        def corroborated?(candidate) = names_agree?(candidate) && !year_conflict?(candidate)

        def names_agree?(candidate)
          candidate.entity.names.any? { |name| author_name_keys.include?(name_key(name)) }
        end

        def year_conflict?(candidate)
          years_conflict?(author.birth_year, candidate.entity.birth_year) ||
            years_conflict?(author.death_year, candidate.entity.death_year)
        end

        def years_conflict?(ours, theirs)
          ours.present? && theirs.present? && (ours - theirs).abs > YEAR_TOLERANCE
        end

        def id_hit?(candidate)
          candidate.sources.intersect?(%w[held_id id_bridge]) || shared_identifiers(candidate).any?
        end

        # Identifier hits first, then shared titles, exact name, fame.
        def ordered_persons
          persons.each_with_index.sort_by do |candidate, index|
            [id_hit?(candidate) ? 0 : 1, -candidate.matching_titles.size, names_agree?(candidate) ? 0 : 1,
              -candidate.entity.sitelink_count, index]
          end.map(&:first)
        end

        def shared_identifiers(candidate)
          shared = []
          shared << {"type" => QID, "value" => candidate.entity.id} if candidate.sources.include?("held_id")
          SHARED_IDENTIFIER_KINDS.each do |kind, type|
            ours = identifier_values(type)
            candidate.entity.identifiers(kind).map { |value| value.delete(" ") }.each do |value|
              shared << {"type" => type, "value" => value} if ours.include?(value)
            end
          end
          shared
        end

        # ---- our side -------------------------------------------------------

        def identifier_values(type)
          @identifiers ||= author.identifiers.to_a
          @identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end

        def bridge_pairs
          BRIDGE_PROPERTIES.flat_map { |type, property| identifier_values(type).map { |value| [property, value.delete(" ")] } }.uniq
        end

        def search_names
          ([author.name] + Array(author.alternate_names)).map { |name| name.to_s.squish }.reject(&:blank?)
            .uniq { |name| name_key(name) }.first(1 + ALTERNATE_SEARCHES)
        end

        def author_name_keys
          @author_name_keys ||= ([author.name] + Array(author.alternate_names)).map { |name| name_key(name) }.compact_blank.to_set
        end

        # Case, diacritics and the letters NFD leaves whole folded, and a
        # hyphen read as a space: "Gabriel Garcia Marquez" meets "Gabriel
        # García Márquez", "Stanislaw" meets "Stanisław", "Jean Paul" meets "Jean-Paul".
        def name_key(text)
          ::Services::Text::NameFolder.call(normalized(text)).gsub(HYPHENS, " ").squeeze(" ").strip
        end

        def title_key(text) = normalized(text).downcase

        def normalized(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s
        end

        # ---- describing -----------------------------------------------------

        def describe(candidate)
          entity = candidate.entity
          parts = [entity.label || entity.id]
          parts << entity.description if entity.description.present?
          span = AuthorProfile.lifespan(entity.birth_year, entity.death_year)
          parts << span if span
          parts << "also known as #{entity.aliases.first(5).join(", ")}" if entity.aliases.any?
          occupations = label_list(entity.occupation_ids)
          parts << "occupations: #{occupations.first(5).join(", ")}" if occupations.any?
          citizenships = label_list(entity.citizenship_ids)
          parts << "citizenship: #{citizenships.join(", ")}" if citizenships.any?
          parts << "works matching ours: #{candidate.matching_titles.first(5).join("; ")}" if candidate.matching_titles.any?
          others = candidate.titles - candidate.matching_titles
          parts << "other works: #{others.first(5).join("; ")}" if others.any?
          parts << "English Wikipedia: #{entity.enwiki_title}" if entity.enwiki_title
          parts << "#{entity.sitelink_count} sitelinks"
          shared = shared_identifiers(candidate).map { |identifier| identifier["type"] }.uniq
          parts << "shares #{shared.join(", ")}" if shared.any?
          parts << "year conflict" if year_conflict?(candidate)
          parts << "wikidata #{entity.id}"
          parts.join(" | ")
        end

        def label_list(ids) = ids.filter_map { |id| labels[id] }

        # ---- recording ------------------------------------------------------

        def record(verdict)
          ordered = ordered_persons + (@candidates.values - persons)
          # Settled before the snapshots read labels: a labels failure there
          # only blanks evidence shown on the audit page, which no rule used.
          # One the AI saw (describe) is already in @sources_failed by now.
          confidence = verdict.confidence
          confidence = :medium if confidence == :high && @sources_failed.any?
          snapshots = ordered.map { |candidate| snapshot(candidate) }
          decision = ::MatchDecision.create!(
            finder: self.class.name,
            subject: author,
            record: nil,
            outcome: (verdict.outcome == :matched) ? :matched : :unmatched,
            confidence: confidence,
            decided_by: verdict.decided_by,
            verify: false,
            query: author_snapshot,
            candidates: snapshots,
            selected_index: verdict.candidate && (ordered.index(verdict.candidate) + 1),
            reason: verdict.reason,
            ai_chat: verdict.ai_chat,
            sources_failed: @sources_failed,
            needs_review: verdict.decided_by == :fallback || %i[medium low].include?(confidence)
          )
          stored = (verdict.outcome == :matched) ? store(verdict.candidate.entity) : nil
          Result.new(
            success?: true,
            data: {
              outcome: verdict.outcome, entity: verdict.candidate&.entity, record: stored, decision: decision,
              reason: verdict.reason, redirected_ids: redirected_ids(verdict.candidate)
            },
            errors: []
          )
        end

        # Ids Wikidata has merged into the chosen item: an author holding one
        # holds the same person under an old id, which is not a conflict.
        def redirected_ids(candidate)
          return [] if candidate.nil?

          @redirects.select { |_requested, target| target == candidate.entity.id }.keys
        end

        def author_snapshot
          {
            "name" => author.name,
            "alternate_names" => Array(author.alternate_names).first(10),
            "birth_year" => author.birth_year,
            "death_year" => author.death_year,
            "open_library_author_key" => identifier_values("books_author_openlibrary_id"),
            "wikidata_qid" => identifier_values(QID),
            "viaf" => identifier_values("books_author_viaf"),
            "titles" => @profile.titles.first(10)
          }.merge(rejected_snapshot)
        end

        def rejected_snapshot
          ids = @rejected.ids(:wikidata)
          ids.any? ? {"rejected" => ids.to_a.sort} : {}
        end

        def snapshot(candidate)
          entity = candidate.entity
          evidence = {
            "external_title" => entity.label || entity.id,
            "external_year" => entity.birth_year,
            "description" => entity.description,
            "aliases" => entity.aliases.first(10),
            "birth_year" => entity.birth_year,
            "death_year" => entity.death_year,
            "instance_of" => entity.instance_of,
            "enwiki_title" => entity.enwiki_title,
            "sitelink_count" => entity.sitelink_count
          }
          if entity.person?
            shared = shared_identifiers(candidate)
            evidence.merge!(
              "occupations" => label_list(entity.occupation_ids),
              "citizenships" => label_list(entity.citizenship_ids),
              "matching_titles" => candidate.matching_titles.first(10),
              "other_titles" => (candidate.titles - candidate.matching_titles).first(5),
              "shared_identifiers" => shared,
              "year_conflict" => year_conflict?(candidate)
            )
            evidence["matched_identifier"] = shared.first if shared.any?
          else
            evidence["dropped"] = "not a person"
          end
          {
            "record_type" => nil, "record_id" => nil,
            "external_source" => "wikidata", "external_key" => entity.id,
            "sources" => candidate.sources, "scores" => {},
            "evidence" => evidence.compact
          }
        end

        # Only the chosen item is kept (spec §3). One read from storage this
        # run is already held and has no fresh body to write.
        def store(entity)
          raw = @raw[entity.id]
          return ::ExternalRecord.find_by(source: :wikidata, source_id: entity.id) if raw.nil?

          ::Services::ExternalRecords::Store.write(source: :wikidata, source_id: entity.id, payload: entity.payload,
            raw: raw, schema_version: ::Wikidata::Distiller::SCHEMA_VERSION)
        end
      end
    end
  end
end
