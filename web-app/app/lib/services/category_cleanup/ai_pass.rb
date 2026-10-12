# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.2 steps 2-4: sends one type's undecided head or tail categories
    # to the AI, most-linked first, and writes the answers as decisions. The
    # head always goes one per call; the tail uses the calibrated batch size.
    # Resumable: a category already decided in this stage is never re-sent, so
    # an interrupted run just continues (REDO=1 on the rake task starts over).
    class AiPass
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      TASKS = {
        "location" => "::Services::Ai::Tasks::CategoryCleanup::LocationTask",
        "subject" => "::Services::Ai::Tasks::CategoryCleanup::SubjectTask"
      }.freeze
      BUILDERS = {"location" => "LocationDecisions", "subject" => "SubjectDecisions"}.freeze

      def self.task_class(category_type) = TASKS.fetch(category_type.to_s).constantize

      def self.task_entry(entry, key)
        ::Services::Ai::Tasks::CategoryCleanup::BaseCleanupTask::Entry.new(
          key: key, name: entry.name, links: entry.links,
          samples: SampleTitles.for(entry.category), alternative_names: entry.category.alternative_names
        )
      end

      attr_reader :stage

      def initialize(run:, category_type:, tier:, batch_size: nil, limit: nil)
        @run = run
        @category_type = category_type.to_s
        @tier = tier.to_sym
        @batch_size = (@tier == :head) ? 1 : (batch_size || Rails.configuration.x.categories_cleanup.tail_batch_size)
        @limit = limit.to_i.positive? ? limit.to_i : nil
        @stage = "#{@category_type.pluralize}_#{@tier}"
      end

      def call_count
        (candidates.size / @batch_size.to_f).ceil
      end

      def call
        stats = {candidates: candidates.size, decided: 0, failed_calls: 0, missing: 0}
        known = own_index.head_names
        candidates.each_slice(@batch_size) { |batch| process(batch, known, stats) }
        Result.new(success?: true, data: stats, errors: [])
      end

      private

      def locations = @locations ||= NameIndex.new(run: @run, category_type: "location")

      def subjects = @subjects ||= NameIndex.new(run: @run, category_type: "subject")

      def own_index = (@category_type == "location") ? locations : subjects

      def candidates
        @candidates ||= begin
          seen = ::CategoryCleanupDecision.for_run(@run)
            .where(stage: ["#{@category_type.pluralize}_head", "#{@category_type.pluralize}_tail"])
            .distinct.pluck(:category_id).to_set
          head_min = Rails.configuration.x.categories_cleanup.head_min_links
          list = own_index.entries
            .select { |entry| (@tier == :head) == (entry.links >= head_min) }
            .reject { |entry| seen.include?(entry.id) }
            .sort_by { |entry| [-entry.links, entry.id] }
          @limit ? list.first(@limit) : list
        end
      end

      def process(batch, known, stats)
        entries = batch.each_with_index.map { |entry, index| self.class.task_entry(entry, (index + 1).to_s) }
        parent = batch.one? ? batch.first.category : nil
        result = self.class.task_class(@category_type).new(entries: entries, known_names: known, tier: @tier, parent: parent).call
        unless result.success?
          stats[:failed_calls] += 1
          return
        end

        batch.each_with_index do |entry, index|
          answer = result.data[:results][(index + 1).to_s]
          if answer.nil?
            batch.one? ? stats[:missing] += 1 : process([entry], known, stats)
            next
          end
          persist(entry, answer, result.ai_chat)
          stats[:decided] += 1
        end
      end

      # One transaction per category: a crash never leaves half its decisions.
      def persist(entry, answer, ai_chat)
        builder = "::Services::CategoryCleanup::#{BUILDERS.fetch(@category_type)}".constantize
        snapshot = ::CategoryCleanupDecision.snapshot_of(entry.category)
        attributes = builder.call(entry: entry, result: answer, locations: locations, subjects: subjects)
        ::CategoryCleanupDecision.transaction do
          attributes.each do |attrs|
            ::CategoryCleanupDecision.create!(
              attrs.merge(run: @run, stage: @stage, decided_by: :ai, ai_chat: ai_chat, category_snapshot: snapshot)
            )
          end
        end
      end
    end
  end
end
