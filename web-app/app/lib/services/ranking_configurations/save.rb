# frozen_string_literal: true

# Edits a user-owned ranking configuration and syncs its penalty
# applications in one transaction. A penalty is on when it has a row and off
# when it does not (spec §2 #4), so enabling creates, disabling destroys.
# Marks the configuration stale only when the computed result would change:
# a RANKING_SETTINGS attribute or any penalty row. Name, description and
# user_shared never do.
module Services
  module RankingConfigurations
    class Save
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(config:, entry:, attributes:, penalties: {})
        new(config: config, entry: entry, attributes: attributes, penalties: penalties).call
      end

      def initialize(config:, entry:, attributes:, penalties:)
        @config = config
        @entry = entry
        @attributes = attributes
        @penalties = penalties
      end

      def call
        ::RankingConfiguration.transaction do
          config.assign_attributes(attributes)
          settings_changed = (config.changed & ::RankingConfiguration::RANKING_SETTINGS).any?
          config.save!
          penalties_changed = sync_penalties
          config.update!(needs_refresh: true) if settings_changed || penalties_changed
        end

        Result.new(success?: true, data: {ranking_configuration: config}, errors: [])
      rescue ActiveRecord::RecordInvalid => e
        messages = e.record.errors.full_messages
        messages.each { |message| config.errors.add(:base, message) } unless config.nil? || e.record.equal?(config)
        Result.new(success?: false, data: {ranking_configuration: config}, errors: messages)
      end

      private

      attr_reader :config, :entry, :attributes, :penalties

      def sync_penalties
        changed = false
        existing = config.penalty_applications.index_by(&:penalty_id)

        ::RankingConfigurations::Registry.penalties_for(entry).find_each do |penalty|
          submitted = penalties[penalty.id.to_s] || {}
          enabled = ActiveModel::Type::Boolean.new.cast(submitted["enabled"])
          application = existing[penalty.id]

          if enabled
            application ||= config.penalty_applications.build(penalty: penalty)
            application.value = submitted["value"]
            next unless application.new_record? || application.changed?

            application.save!
            changed = true
          elsif application
            application.destroy!
            changed = true
          end
        end

        changed
      end
    end
  end
end
