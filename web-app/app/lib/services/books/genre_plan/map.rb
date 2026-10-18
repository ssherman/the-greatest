# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:map` (spec §5 step 3). Resumable: genres already in
      # the file are skipped, which also covers genres added later. A failed
      # batch writes nothing and is retried on the next run.
      class Map
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(path: PlanFile::DEFAULT_PATH, batch_size: 30, map: ::Books::WorldCat::GenreMap.load)
          new(path, batch_size, map).call
        end

        def initialize(path, batch_size, map)
          @plan = PlanFile.load(path)
          @batch_size = batch_size
          @worldcat_terms = map.terms_by_genre
        end

        def call
          return Result.new(success?: false, data: nil, errors: ["#{@plan.path} has no genre list; run draft first"]) if @plan.genres.empty?

          references = References.call
          pending = ::Books::Category.active.genre.where.not(id: @plan.decisions.keys).order(item_count: :desc, id: :asc).to_a
          mapped = 0
          failed = 0
          batches = 0
          pending.each_slice(@batch_size) do |slice|
            batches += 1
            # Every WorldCat term that targets a split genre is input: the task
            # fails a batch whose split answer omits one.
            entries = slice.each_with_index.map do |category, index|
              ::Services::Ai::Tasks::Books::GenreMapTask::Entry.new(key: (index + 1).to_s, name: category.name,
                books: category.item_count.to_i, samples: ::Services::CategoryCleanup::SampleTitles.for(category),
                references: references[category.id], worldcat_terms: @worldcat_terms.fetch(category.name, []))
            end
            response = ::Services::Ai::Tasks::Books::GenreMapTask.new(entries: entries, genres: @plan.genres, audiences: @plan.audiences).call
            unless response.success?
              failed += 1
              Rails.logger.warn("[genre map] batch failed: #{response.error}")
              next
            end

            slice.each_with_index do |category, index|
              @plan.decisions[category.id] = decision_for(category, response.data[:results].fetch((index + 1).to_s), references)
              mapped += 1
            end
            @plan.write
          end
          remaining = ::Books::Category.active.genre.where.not(id: @plan.decisions.keys).count
          Result.new(success?: true, data: {mapped: mapped, batches: batches, failed_batches: failed, remaining: remaining}, errors: [])
        end

        private

        def decision_for(category, r, references)
          d = {"name" => category.name, "action" => r[:action], "reason" => r[:reason],
               "books" => category.item_count.to_i, "saved_searches" => references[category.id]}
          case r[:action]
          when "rename" then d["to"] = r[:to]
          when "merge" then d["into"] = r[:into].first
          when "audience" then d["as"] = r[:as]
          when "subject"
            d["as"] = r[:as] if r[:as]
            target = find(:subject, r[:as] || category.name)
            d["target_id"] = target.id if target
            d["as"] = target.name if target
          when "location"
            target = find(:location, r[:as] || category.name)
            if target
              d["as"] = target.name
              d["target_id"] = target.id
            else
              d["action"] = "delete"
              d["reason"] = "no such location: #{r[:as] || category.name}"
            end
          when "split"
            subjects = []
            r[:into_subjects].each do |name|
              target = find(:subject, name)
              if target
                subjects << {"subject" => target.name, "target_id" => target.id}
              else
                d["reason"] = "#{d["reason"]} (no subject named #{name})"
              end
            end
            d["into"] = r[:into] + subjects
            d["worldcat_terms"] = r[:worldcat_terms] if r[:worldcat_terms].any?
          end
          d["also"] = r[:also] if r[:also].any? && %w[keep rename].include?(d["action"])
          d["worldcat"] = r[:worldcat] if r[:worldcat]
          d
        end

        def find(type, name)
          scope = ::Books::Category.active.where(category_type: type)
          scope.by_name(name).first || scope.by_alternative_name(name).first
        end
      end
    end
  end
end
