# frozen_string_literal: true

# Creates a user-owned ranking configuration in one transaction -- the row,
# its penalty applications, and (official start with seed_lists) one INSERT
# of every list the official configuration ranks -- then requests the first
# refresh. That automatic run never passes through the rate-limited
# controller action, which is how it stays exempt from the daily cap.
#
# Model constants are root-anchored: Services::RankingConfiguration is an
# existing module, so a bare RankingConfiguration here would resolve to it.
module Services
  module RankingConfigurations
    class Create
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      NO_PRIMARY = "There is no official ranking to copy from"

      def self.call(user:, entry:, attributes:, penalties: {}, start: :official, seed_lists: true)
        new(user: user, entry: entry, attributes: attributes, penalties: penalties, start: start, seed_lists: seed_lists).call
      end

      def initialize(user:, entry:, attributes:, penalties:, start:, seed_lists:)
        @user = user
        @entry = entry
        @attributes = attributes
        @penalties = penalties
        @start = start.to_sym
        @seed_lists = seed_lists
      end

      def call
        primary = configuration_class.default_primary if official?
        return failure(configuration_class.new, [NO_PRIMARY]) if official? && primary.nil?

        config = build(primary)
        config.assign_attributes(attributes)

        ::RankingConfiguration.transaction do
          # Serialises creates per owner so two simultaneous requests cannot
          # both count four and both insert a sixth (the cap validation runs
          # inside this lock). Same shape as ReadingGoals::SaveGoal.
          ::User.lock.find(user.id)
          config.save!
          apply_penalties(config)
          seed_lists_from(primary, config) if official? && seed_lists
        end

        RequestRefresh.call(config: config)
        Result.new(success?: true, data: {ranking_configuration: config}, errors: [])
      rescue ActiveRecord::RecordInvalid => e
        messages = e.record.errors.full_messages
        messages.each { |message| config.errors.add(:base, message) } unless config.nil? || e.record.equal?(config)
        failure(config || configuration_class.new, messages)
      end

      private

      attr_reader :user, :entry, :attributes, :penalties, :start, :seed_lists

      def official? = start == :official

      def configuration_class
        @configuration_class ||= entry.ranking_configuration_class.constantize
      end

      def build(primary)
        return configuration_class.new(global: false, user: user, needs_refresh: true) unless official?

        config = primary.dup
        config.assign_attributes(
          global: false,
          user: user,
          user_shared: false,
          primary: false,
          archived: false,
          published_at: nil,
          year: nil,
          list_limit: nil,
          primary_mapped_list_id: nil,
          secondary_mapped_list_id: nil,
          primary_mapped_list_cutoff_limit: nil,
          secondary_mapped_list_cutoff_limit: nil,
          inherited_from_id: primary.id,
          min_list_weight: primary.weight_floor,
          refresh_status: :idle,
          needs_refresh: true,
          refresh_requested_at: nil,
          last_refreshed_at: nil,
          last_refresh_error: nil
        )
        config
      end

      # Iterates the catalogue, not the params: an unknown or foreign id is
      # ignored, and a missing key means off. Parent first, then children.
      def apply_penalties(config)
        ::RankingConfigurations::Registry.penalties_for(entry).find_each do |penalty|
          submitted = penalties[penalty.id.to_s]
          next unless submitted && ActiveModel::Type::Boolean.new.cast(submitted["enabled"])

          config.penalty_applications.create!(penalty: penalty, value: submitted["value"])
        end
      end

      def seed_lists_from(primary, config)
        list_ids = primary.ranked_lists.pluck(:list_id)
        return if list_ids.empty?

        now = Time.current
        ::RankedList.insert_all(list_ids.map { |list_id|
          {list_id: list_id, ranking_configuration_id: config.id, created_at: now, updated_at: now}
        })
      end

      def failure(config, errors)
        Result.new(success?: false, data: {ranking_configuration: config}, errors: errors)
      end
    end
  end
end
