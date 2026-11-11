module Actions
  module Admin
    # Archives a configuration's current ranking under an admin-typed name. With no
    # period the archive is a manual one, so it never blocks the monthly archive.
    class ArchiveRanking < Actions::Admin::BaseAction
      def self.name
        "Archive Now"
      end

      def self.message
        "Freeze the current ranking as a named archive."
      end

      def self.visible?(context = {})
        context[:view] == :show
      end

      def call
        return error("This action can only be performed on a single configuration.") if models.count != 1

        name = fields[:name].to_s.strip
        return error("Give the archive a name.") if name.blank?

        config = models.first
        result = ::Services::RankingArchives::Capture.call(config: config, name: name)
        return error(result.errors.join(" ")) unless result.success?

        succeed(%(Archived #{config.name} as "#{result.data.name}" (#{result.data.items_count} items).))
      end
    end
  end
end
