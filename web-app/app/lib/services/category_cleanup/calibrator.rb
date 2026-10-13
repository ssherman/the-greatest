# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.4: runs a seeded sample of tail categories through the AI at
    # several batch sizes and reports how often each batched answer agrees with
    # the one-at-a-time answer. Writes no decisions; the owner reads the
    # numbers and sets config.x.categories_cleanup.tail_batch_size.
    #
    # The one-at-a-time answers are not stable themselves (two passes agreed on
    # 86-88% of categories in the 2026-10-12 dev rehearsal), so a second
    # one-at-a-time pass is the baseline: a batch size that agrees about as
    # well as the baseline loses nothing to batching.
    class Calibrator
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      SIZES = [1, 10, 25].freeze
      SAMPLE_SIZE = 200

      def self.call(run:, category_type:, sample_size: SAMPLE_SIZE, seed: 42, sizes: SIZES, baseline: true)
        new(run: run, category_type: category_type, sample_size: sample_size, seed: seed, sizes: sizes, baseline: baseline).call
      end

      def initialize(run:, category_type:, sample_size:, seed:, sizes:, baseline:)
        @run = run
        @baseline = baseline
        @category_type = category_type.to_s
        @sample_size = sample_size
        @seed = seed
        @sizes = sizes
      end

      def call
        index = NameIndex.new(run: @run, category_type: @category_type)
        head_min = Rails.configuration.x.categories_cleanup.head_min_links
        # The tail is decided by a category's own direct links, as AiPass does.
        tail = index.entries.select { |entry| entry.own_links < head_min }.sort_by(&:id)
        sample = tail.sample([@sample_size, tail.size].min, random: Random.new(@seed))
        known = index.head_names

        answers = @sizes.to_h { |size| [size, ask(sample, size, known)] }
        reference = answers.fetch(@sizes.first)
        rows = @sizes.drop(1).map { |size| compare(size, reference, answers.fetch(size)) }
        baseline = @baseline ? compare(@sizes.first, reference, ask(sample, @sizes.first, known)) : nil
        Result.new(success?: true, data: {sample: sample.size, baseline: baseline, sizes: rows}, errors: [])
      end

      private

      def ask(sample, size, known)
        sample.each_slice(size).each_with_object({}) do |batch, out|
          entries = batch.each_with_index.map { |entry, index| AiPass.task_entry(entry, (index + 1).to_s) }
          result = AiPass.task_class(@category_type).new(entries: entries, known_names: known, tier: :tail).call
          next unless result.success?

          batch.each_with_index do |entry, index|
            answer = result.data[:results][(index + 1).to_s]
            out[entry.id] = {name: entry.name, signature: signature(answer)} if answer
          end
        end
      end

      # What must match for two answers to count as the same decision. A name
      # with no letters has a nil key; nil compares equal to nil.
      def signature(answer)
        key = ->(name) { NameNormalizer.twin_key(name.to_s) }
        if @category_type == "location"
          [answer[:verdict], key.call(answer[:merge_into]), key.call(Array(answer[:parent_chain]).first), key.call(answer[:canonical_name]),
            answer[:retype_to]]
        else
          [answer[:action], key.call(answer[:name]), key.call(answer[:merge_into])]
        end
      end

      def compare(size, reference, batched)
        compared = reference.keys & batched.keys
        disagreements = compared.reject { |id| reference[id][:signature] == batched[id][:signature] }
        # The first signature element alone: the subject action, or the location verdict.
        same_action = compared.count { |id| reference[id][:signature].first == batched[id][:signature].first }
        {
          size: size,
          compared: compared.size,
          agreement: compared.empty? ? 0.0 : (compared.size - disagreements.size).fdiv(compared.size),
          action_agreement: compared.empty? ? 0.0 : same_action.fdiv(compared.size),
          disagreements: disagreements.map { |id| {name: reference[id][:name], one_at_a_time: reference[id][:signature], batched: batched[id][:signature]} }
        }
      end
    end
  end
end
