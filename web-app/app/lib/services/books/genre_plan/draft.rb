# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:draft` (spec §5 step 1): asks the model for the tight
      # genre list and writes it, with the fixed audiences, to the plan file.
      class Draft
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(path: PlanFile::DEFAULT_PATH, force: false)
          new(path, force).call
        end

        def initialize(path, force)
          @path = path
          @force = force
        end

        def call
          existing = PlanFile.load(@path)
          if existing.decisions.any? && !@force
            return Result.new(success?: false, data: nil, errors: ["#{@path} already has decisions; rerun with FORCE=1 to replace it"])
          end

          references = References.call
          entries = ::Books::Category.active.genre.order(item_count: :desc, name: :asc).map do |category|
            ::Services::Ai::Tasks::Books::GenreDraftTask::Entry.new(name: category.name, books: category.item_count.to_i,
              samples: ::Services::CategoryCleanup::SampleTitles.for(category), references: references[category.id])
          end
          response = ::Services::Ai::Tasks::Books::GenreDraftTask.new(entries: entries).call
          return Result.new(success?: false, data: nil, errors: [response.error]) unless response.success?

          plan = PlanFile.new({
            "run" => "genres-#{Date.current.strftime("%Y-%m")}",
            "genres" => response.data[:genres].map { |g| {"name" => g[:name], "definition" => g[:definition]} },
            "audiences" => PlanFile::AUDIENCES.map { |name, definition| {"name" => name, "definition" => definition} },
            "decisions" => {}
          }, path: @path)
          plan.write
          Result.new(success?: true, data: {genres: plan.genres.size, notes: response.data[:notes]}, errors: [])
        end
      end
    end
  end
end
