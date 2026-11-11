# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Writes the Mapper's resolved categories onto a book by fixed rules, in
      # one transaction under a row lock: (1) snapshot the direct links,
      # (2) on a confident, externally evidenced re-judge remove legacy links
      # that nothing picked and no source supports, (3) the Fiction/Nonfiction
      # type, (4) additions under the per-type caps, (5) reconcile ancestors.
      # A legacy link the judge named is protected even when the mapper lost the
      # name (declined, or outside the candidates): see `named_by_unmatched?`.
      # Only `legacy` links are ever removed; Fiction, Nonfiction and audiences
      # never are. Never creates a Category.
      class Apply
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        TYPES = %w[genre audience subject location].freeze
        CAPS = {"genre" => 5, "subject" => 8, "location" => 5, "audience" => 1}.freeze
        CONFIDENCE_ORDER = {"high" => 0, "medium" => 1}.freeze
        TYPE_NAMES = ::Books::Book::BOOK_TYPE_CATEGORY_NAMES

        def self.call(book:, dossier:, answer:, resolved:, rejudge:, unmatched: [])
          new(book: book, dossier: dossier, answer: answer, resolved: resolved, rejudge: rejudge, unmatched: unmatched).call
        end

        def initialize(book:, dossier:, answer:, resolved:, rejudge:, unmatched: [])
          @book = book
          @dossier = dossier
          @answer = (answer || {}).deep_stringify_keys
          @resolved = resolved || []
          @rejudge = rejudge
          @unmatched = unmatched || []
          @added = []
          @confirmed = []
          @removed = []
          @held_back = []
          @wrote = false
        end

        def call
          type_result = nil
          rejudged = false
          book.with_lock do
            snapshot
            rejudged = rejudge_conditions?
            remove_unsupported if rejudged
            type_result = apply_type
            add_resolved
            ::Categories::AncestorReconciler.call(item_ids: [book.id]) if @wrote
          end
          Result.new(success?: true, errors: [], data: {added: @added, confirmed: @confirmed, removed: @removed,
                                                        held_back: @held_back, type: type_result, rejudged: rejudged})
        end

        private

        attr_reader :book, :dossier, :answer, :resolved

        def support = (@support ||= Support.new(dossier))

        def type_category?(category) = category.genre? && TYPE_NAMES.include?(category.name)

        # Direct links of the four types, Fiction and Nonfiction aside.
        def snapshot
          @links = book.category_items.direct.includes(:category).select do |link|
            TYPES.include?(link.category.category_type) && !type_category?(link.category)
          end
          @counts = @links.group_by { |link| link.category.category_type }.transform_values(&:size)
          @counts.default = 0
        end

        def rejudge_conditions?
          @rejudge && answer["recognized"] == true && answer["confidence"] == "high" && dossier.external?
        end

        def resolved_types
          # Only a confident pick shows the judge covered the type; a low pick still protects (picked_ids).
          @resolved_types ||= resolved.select { |entry| CONFIDENCE_ORDER.key?(entry[:confidence]) }
            .map { |entry| entry[:category].category_type }.to_set
        end

        # The category ids the chooser was offered for an unmatched name, per type.
        def unmatched_candidate_ids
          @unmatched_candidate_ids ||= @unmatched.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |entry, ids|
            ids[entry[:type].to_s].merge(Array(entry[:candidate_ids]))
          end
        end

        # Twin keys of every name the judge proposed, matched or not, per type.
        def proposed_keys
          @proposed_keys ||= (resolved + @unmatched).each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |entry, keys|
            # Genres and audiences arrive as ids, not names.
            next unless %w[subject location].include?(entry[:type].to_s)

            # A fictional place mapped to its real parent keeps the name it was proposed under.
            [entry[:proposed], entry[:original]].each do |name|
              key = ::Services::CategoryCleanup::NameNormalizer.twin_key(name)
              keys[entry[:type].to_s] << key if key
            end
          end
        end

        # The judge named this legacy link but the mapper lost the name.
        def named_by_unmatched?(category)
          type = category.category_type
          return true if unmatched_candidate_ids[type].include?(category.id)

          names = ([category.name] + Array(category.alternative_names)).filter_map { |name| ::Services::CategoryCleanup::NameNormalizer.twin_key(name) }
          (names.to_set & proposed_keys[type]).any?
        end

        def picked_ids
          @picked_ids ||= resolved.flat_map do |entry|
            ids = [entry[:category].id]
            ids += entry[:category].ancestors.map(&:id) if entry[:category].location?
            ids
          end.to_set
        end

        # A legacy subject whose name (or an alternative name) is a whole word or phrase inside a
        # picked subject's name is covered by that pick: Gender inside Gender Roles. Any confidence.
        def named_inside_picked_subject?(category)
          return false unless category.subject?

          names = ([category.name] + Array(category.alternative_names)).map { |name| name.to_s.strip }.reject(&:empty?)
          picked_subject_names.any? do |picked|
            names.any? { |name| picked.match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i) }
          end
        end

        def picked_subject_names
          @picked_subject_names ||= resolved.map { |entry| entry[:category] }.select(&:subject?).map(&:name).uniq
        end

        def remove_unsupported
          @links.select(&:source_legacy?).each do |link|
            category = link.category
            next if category.audience?
            # A type the mapping produced nothing for is never stripped: silence is not evidence.
            next unless resolved_types.include?(category.category_type)
            next if picked_ids.include?(category.id)
            next if named_by_unmatched?(category)
            next if named_inside_picked_subject?(category)
            next if support.supported?(category)

            link.destroy!
            @wrote = true
            @counts[category.category_type] -= 1
            @removed << {id: category.id, name: category.name, type: category.category_type, source: "legacy"}
          end
        end

        def apply_type
          value = answer.dig("book_type", "value").to_s
          confidence = answer.dig("book_type", "confidence")
          held = held_type
          result = {judged: value.presence, confidence: confidence, held: held, applied: false}
          wanted = value.capitalize
          return result.merge(reason: "no_type") unless TYPE_NAMES.include?(wanted)
          return result.merge(reason: "type_conflict") if held && held != wanted
          return result.merge(reason: "held") if held == wanted
          return result.merge(reason: "not_high") unless confidence == "high"
          return result.merge(reason: "book_facts_disagrees") if facts_type && facts_type != wanted

          category = ::Books::Category.find_by(name: wanted, category_type: "genre", deleted: false)
          return result.merge(reason: "no_type") unless category

          book.category_items.create!(category: category, source: :ai)
          @wrote = true
          result.merge(applied: true, reason: "applied")
        end

        def held_type
          book.category_items.includes(:category).map { |link| link.category.name if type_category?(link.category) }.compact.first
        end

        def facts_type
          raw = dossier.book_facts.is_a?(Hash) ? dossier.book_facts["book_type"] : nil
          raw = raw["value"] if raw.is_a?(Hash)
          raw.to_s.capitalize.presence_in(TYPE_NAMES)
        end

        def add_resolved
          seen = Set.new
          ordered = resolved.each_with_index.sort_by { |entry, index| [CONFIDENCE_ORDER.fetch(entry[:confidence], 2), index] }.map(&:first)
          ordered.each do |entry|
            category = entry[:category]
            next unless seen.add?(category.id)

            add_entry(entry, category)
          end
        end

        def add_entry(entry, category)
          type = category.category_type
          return hold(entry, category, "low_confidence") unless CONFIDENCE_ORDER.key?(entry[:confidence])

          existing = book.category_items.find_by(category_id: category.id)
          # A medium pick needs the looser, addition-only support (held, prose, shelf names);
          # removals still use the stricter supported?.
          sources = (entry[:confidence] == "medium") ? support.addition_sources(category, held: existing.present?) : support.sources_for(category)
          return hold(entry, category, "unsupported_medium") if entry[:confidence] == "medium" && sources.empty?

          if existing
            return unless existing.source_legacy? || existing.source_inherited?

            from = existing.source
            return hold(entry, category, "cap") if from == "inherited" && @counts[type] >= CAPS.fetch(type)

            existing.update!(source: :ai)
            @counts[type] += 1 if from == "inherited"
            @wrote = true
            @confirmed << {id: category.id, name: category.name, type: type, from: from}
          elsif @counts[type] < CAPS.fetch(type)
            book.category_items.create!(category: category, source: :ai)
            @counts[type] += 1
            @wrote = true
            @added << {id: category.id, name: category.name, type: type, confidence: entry[:confidence], support: sources}
          else
            hold(entry, category, "cap")
          end
        end

        def hold(entry, category, reason)
          @held_back << {id: category.id, name: category.name, type: category.category_type, confidence: entry[:confidence], reason: reason}
        end
      end
    end
  end
end
