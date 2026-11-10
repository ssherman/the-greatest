# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Turns BookCategoriesTask's answer into categories. Genres and the audience
      # arrive as ids and are checked against the vocabulary the caller passed.
      # Subjects and locations arrive as names: an exact match on name or
      # alternative name (merged rows included, following the merge), then one
      # CategoryChoiceTask call for every name still open, then unmatched. Nothing
      # is ever created. Pure lookup apart from that one AI call.
      class Mapper
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        LABEL_SEPARATOR = " › "
        CANDIDATE_LIMIT = 10
        MAX_DEPTH = 12
        ROW_COLUMNS = %i[id name alternative_names parent_id merged_into_id deleted].freeze
        Row = Struct.new(*ROW_COLUMNS, keyword_init: true)
        Item = Struct.new(:type, :proposed, :confidence, :evidence, :kind, :hint, :index, :category_id, :via, :unmatched_via, :candidate_ids, keyword_init: true)

        def self.call(book:, answer:, vocabulary:)
          new(book: book, answer: answer, vocabulary: vocabulary).call
        end

        def initialize(book:, answer:, vocabulary:)
          @book = book
          @answer = (answer || {}).deep_stringify_keys
          # Fiction and Nonfiction are the book type, never a judged genre, whatever the caller listed.
          @vocabulary = vocabulary.reject { |category| category.genre? && ::Books::Book::BOOK_TYPE_CATEGORY_NAMES.include?(category.name) }.index_by(&:id)
          @rows = {}
          @candidates = {}
        end

        def call
          items = genre_items + audience_items + named_items("subject", "subjects") + named_items("location", "locations")
          items.each { |item| resolve_by_name(item) if named?(item) && item.category_id.nil? && item.unmatched_via.nil? }

          chat = nil
          open_items = items.select { |item| named?(item) && item.category_id.nil? && item.candidate_ids.present? }
          if open_items.any?
            result = ask_chooser(open_items)
            return Result.new(success?: false, data: nil, errors: [result.error]) unless result.success?

            chat = result.ai_chat
            apply_choices(open_items, result.data)
          end

          items.each { |item| item.unmatched_via ||= "no_candidate" if item.category_id.nil? }
          settle_fictional_root(items)
          Result.new(success?: true, errors: [], data: build_data(items, chat))
        end

        private

        attr_reader :book, :answer, :vocabulary

        def named?(item) = %w[subject location].include?(item.type)

        # ---- genres and audience: by id ------------------------------------

        def genre_items
          Array(answer["genres"]).map { |entry| id_item("genre", entry) }
        end

        def audience_items
          entry = answer["audience"]
          return [] if entry.blank? || entry["id"].nil?

          [id_item("audience", entry)]
        end

        def id_item(type, entry)
          category = vocabulary[Integer(entry["id"], exception: false)]
          item = Item.new(type: type, proposed: entry["id"].to_s, confidence: entry["confidence"], evidence: entry["evidence"])
          if category && category.category_type == type
            item.category_id = category.id
            item.via = "id"
          else
            item.unmatched_via = "invalid_id"
          end
          item
        end

        # ---- subjects and locations: by name -------------------------------

        def named_items(type, key)
          Array(answer[key]).each_with_index.map do |entry, index|
            Item.new(type: type, proposed: entry["name"].to_s, confidence: entry["confidence"], evidence: entry["evidence"],
              kind: entry["kind"], hint: entry["parent"], index: index)
          end
        end

        def resolve_by_name(item)
          exact = exact_matches(item)
          if exact.size == 1
            item.category_id, item.via = exact.first
            return
          end

          candidates = find_candidate_ids(item, exact.map(&:first))
          item.candidate_ids = candidates if candidates.any?
        end

        # Every [category_id, via] the name reaches without the AI: active rows first,
        # then (only when the active rows give none) merged rows followed to their target.
        def exact_matches(item)
          key = ::Services::CategoryCleanup::NameNormalizer.twin_key(item.proposed)
          return [] unless key

          active = keyed(item.type, :active)[key].to_a.uniq.select { |id| fits?(item, id) }
          return active.map { |id| [id, "exact"] } if active.any?

          merged = keyed(item.type, :merged)[key].to_a.uniq.select { |id| fits?(item, id) }
          merged.map { |id| [id, "merged"] }
        end

        # Real or fictional subtree, and for a location the parent hint.
        def fits?(item, id)
          return true unless item.type == "location"
          return false if fictional_ids.include?(id) != fictional_filter(item)

          hint_matches?(item, id)
        end

        def fictional_filter(item)
          item.kind.to_s.strip.downcase == "fictional"
        end

        def fictional_ids = (@fictional_ids ||= Candidates.fictional_ids)

        def hint_matches?(item, id)
          proposed_key = ::Services::CategoryCleanup::NameNormalizer.twin_key(item.proposed)
          hint = item.hint.to_s
          keys = ([hint] + hint.split(",")).filter_map { |part| ::Services::CategoryCleanup::NameNormalizer.twin_key(part) }.uniq - [proposed_key]
          return true if keys.empty?

          known = ([id] + ancestor_ids(id)).flat_map do |row_id|
            row = rows("location")[row_id]
            ([row&.name] + Array(row&.alternative_names)).filter_map { |name| ::Services::CategoryCleanup::NameNormalizer.twin_key(name) }
          end
          (keys & known).any?
        end

        def ancestor_ids(id)
          chain = []
          node = rows("location")[id]
          while node&.parent_id && chain.size < MAX_DEPTH
            chain << node.parent_id
            node = rows("location")[node.parent_id]
          end
          chain
        end

        # One load per type per call: id, names and tree columns only.
        def rows(type)
          @rows[type] ||= ::Books::Category.where(category_type: type)
            .pluck(*ROW_COLUMNS).to_h { |values| [values.first, Row.new(**ROW_COLUMNS.zip(values).to_h)] }
        end

        # {twin_key => [active category id]} and {twin_key => [active canonical id]} for merged rows.
        def keyed(type, kind)
          @keyed ||= {}
          @keyed[[type, kind]] ||= begin
            index = Hash.new { |hash, key| hash[key] = [] }
            rows(type).each_value do |row|
              if kind == :active && !row.deleted
                target = row.id
              elsif kind == :merged && row.deleted && row.merged_into_id
                target = canonical_id(type, row)
              end
              next unless target

              ([row.name] + Array(row.alternative_names)).filter_map { |name| ::Services::CategoryCleanup::NameNormalizer.twin_key(name) }.uniq
                .each { |key| index[key] << target }
            end
            index
          end
        end

        # Follows merged_into_id to an active row of the same type (the load is per type), or nil.
        def canonical_id(type, row)
          seen = Set.new
          node = row
          while node&.deleted
            return nil unless node.merged_into_id && seen.add?(node.id) && seen.size <= MAX_DEPTH

            node = rows(type)[node.merged_into_id]
          end
          node&.id
        end

        # ---- candidates and the chooser ------------------------------------

        def find_candidate_ids(item, exact_ids)
          @candidates[item.type] ||= Candidates.new(category_type: item.type)
          found = @candidates[item.type].call(name: item.proposed, fictional: fictional_filter(item), limit: CANDIDATE_LIMIT).map(&:id)
          (exact_ids + found).uniq.first(CANDIDATE_LIMIT)
        end

        def ask_chooser(open_items)
          questions = open_items.map do |item|
            question = {proposed: item.proposed, category_type: item.type,
                        candidates: item.candidate_ids.map { |id| {id: id, label: label(item.type, id)} }}
            question[:hint] = item.hint if item.type == "location" && item.hint.present?
            question
          end
          Services::Ai::Tasks::Books::CategoryChoiceTask.new(parent: book, book_line: book_line, questions: questions).call
        end

        def apply_choices(open_items, data)
          by_question = Array((data || {}).deep_stringify_keys["choices"]).to_h { |choice| [choice["question"], Integer(choice["category_id"], exception: false)] }
          open_items.each_with_index do |item, index|
            id = by_question[index + 1]
            if id && item.candidate_ids.include?(id)
              item.category_id = id
              item.via = "chosen"
            else
              item.unmatched_via = "declined"
            end
          end
        end

        def label(type, id)
          names = []
          node = rows(type)[id]
          while node && names.size <= MAX_DEPTH
            names << node.name
            node = (type == "location") ? rows(type)[node.parent_id] : nil
          end
          names.join(LABEL_SEPARATOR)
        end

        def book_line
          authors = book.authors.map(&:name).first(3).join("; ")
          [book.title, authors.presence && "by #{authors}", book.first_published_year && "(#{book.first_published_year})"].compact.join(" ")
        end

        # ---- fictional root and output -------------------------------------

        # A fictional main setting (first listed) that matched nothing stands for the root.
        def settle_fictional_root(items)
          items.each do |item|
            next unless item.type == "location" && item.category_id.nil? && fictional_filter(item) && item.index == 0

            root = rows("location").values.find { |row| !row.deleted && row.name == Candidates::FICTIONAL_ROOT }
            next unless root

            item.category_id = root.id
            item.via = "fictional_root"
            item.unmatched_via = nil
          end
        end

        def build_data(items, chat)
          categories = ::Books::Category.where(id: items.filter_map(&:category_id)).index_by(&:id)
          seen = Set.new
          resolved = []
          unmatched = []
          items.each do |item|
            category = categories[item.category_id]
            if category
              next unless seen.add?(category.id)

              resolved << {type: item.type, category: category, proposed: item.proposed, confidence: item.confidence, evidence: item.evidence, via: item.via}
            else
              unmatched << {type: item.type, proposed: item.proposed, via: item.unmatched_via || "no_candidate"}
            end
          end
          {resolved: resolved, unmatched: unmatched, ai_chat: chat}
        end
      end
    end
  end
end
