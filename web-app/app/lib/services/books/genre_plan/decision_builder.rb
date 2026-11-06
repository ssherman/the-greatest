# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # Turns the reviewed plan into stage-`genres` CategoryCleanupDecision rows
      # for the run (spec §4 table). Writes nothing when the run already has them.
      class DecisionBuilder
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        STAGE = "genres"

        def self.call(plan:, assignments:)
          new(plan, assignments).call
        end

        def initialize(plan, assignments)
          @plan = plan
          @assignments = assignments
        end

        def call
          scope = ::CategoryCleanupDecision.for_run(@plan.run).where(stage: STAGE)
          return Result.new(success?: true, data: {created: 0, unassigned_split_books: 0}, errors: []) if scope.exists?

          created = 0
          unassigned = 0
          categories = ::Books::Category.where(id: @plan.decisions.keys).index_by(&:id)
          ::CategoryCleanupDecision.transaction do
            @plan.decisions.sort.each do |id, decision|
              category = categories.fetch(id)
              rows_for(category, decision).each do |attrs|
                ::CategoryCleanupDecision.create!(base(category, decision).merge(attrs))
                created += 1
              end
              unassigned += unassigned_books(category) if decision["action"] == "split"
            end
          end
          Result.new(success?: true, data: {created: created, unassigned_split_books: unassigned}, errors: [])
        end

        private

        def base(category, decision)
          {category: category, run: @plan.run, stage: STAGE, decided_by: :ai, reason: decision["reason"],
           category_snapshot: ::CategoryCleanupDecision.snapshot_of(category)}
        end

        def rows_for(category, decision)
          case decision["action"]
          when "keep" then [{action: :keep, extra_target_ids: ids_for(decision["also"])}]
          when "rename" then [{action: :rename, new_name: decision["to"], extra_target_ids: ids_for(decision["also"])}]
          when "merge" then [{action: :merge, target_category_id: producer_id(decision["into"])}]
          when "audience" then retype_rows(category, "audience", decision["as"])
          when "subject"
            decision["target_id"] ? [{action: :merge, target_category_id: decision["target_id"]}] : retype_rows(category, "subject", decision["as"])
          when "location" then [{action: :merge, target_category_id: decision["target_id"]}]
          when "delete" then [{action: :delete}]
          when "split" then [split_row(category, decision)]
          end
        end

        def retype_rows(category, type, new_name)
          rows = [{action: :retype, new_category_type: ::Category.category_types.fetch(type)}]
          rows << {action: :rename, new_name: new_name} if new_name.present? && new_name != category.name
          rows
        end

        def split_row(category, decision)
          into = Array(decision["into"])
          renaming = renaming_split_ids.include?(category.id)
          target_ids = into.each_with_index.map { |entry, i| (i.zero? && renaming) ? category.id : target_id(entry) }
          extras = target_ids.drop(1)
          ids_by_label = into.zip(target_ids).to_h { |entry, id| [Validator.target_label(entry), id] }
          answers = @assignments.for(category.id).each_with_object({}) do |(book_id, labels), out|
            out[book_id.to_s] = labels.map { |label| ids_by_label.fetch(label) } unless labels == :unknown
          end
          row = {action: :split, extra_target_ids: extras, split_assignments: answers}
          renaming ? row.merge(new_name: into.first) : row.merge(target_category_id: target_ids.first)
        end

        def target_id(entry) = entry.is_a?(Hash) ? entry["target_id"].to_i : producer_id(entry)

        def ids_for(names) = Array(names).map { |name| producer_id(name) }

        # List name -> the id of the category that ends as that entry.
        def producer_id(name)
          producers.fetch(name) { raise ArgumentError, "#{name.inspect} is produced by no decision" }
        end

        def producers = build_producers.first

        def renaming_split_ids = build_producers.last

        # [list name -> producing category id, Set of renaming split ids]. Same
        # order as Validator#check_producers: keep/rename/audience first, then
        # live audience rows, then the first split (by id) whose genre-list
        # primary nothing else produces renames to it.
        def build_producers
          @build_producers ||= begin
            map = {}
            renaming = Set.new
            @plan.decisions.sort.each do |id, d|
              case d["action"]
              when "keep" then map[d["name"]] = id
              when "rename" then map[d["to"]] = id
              when "audience" then map[d["as"]] = id
              end
            end
            ::Books::Category.active.audience.where(name: @plan.audience_names).pluck(:name, :id).each { |name, id| map[name] ||= id }
            @plan.decisions.sort.each do |id, d|
              next unless d["action"] == "split"

              primary = Array(d["into"]).first
              next unless primary.is_a?(String) && @plan.genre_names.include?(primary) && !map.key?(primary)

              map[primary] = id
              renaming << id
            end
            [map, renaming]
          end
        end

        def unassigned_books(category)
          answered = @assignments.for(category.id).keys.to_set
          category.category_items.where(item_type: "Books::Book").pluck(:item_id).count { |book_id| !answered.include?(book_id) }
        end
      end
    end
  end
end
