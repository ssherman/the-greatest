# frozen_string_literal: true

# Rebuilds every domain's generated "Our Users' Favorite ..." list from user
# favorites. Scheduled nightly in config/schedule.yml.
#
# Deliberately does NOT recalculate rankings. Ranking recalculation is a heavy
# cascade (600+ lists, then author rankings, then a search reindex) onto a queue
# that is already a throughput bottleneck, and it stays on the deliberate admin
# refresh so a night of favoriting can never silently reshuffle the site.
#
# The legacy implementation ran from UserListBook after_create/after_destroy/
# after_update, so a single user working through their favorites queued hundreds
# of full recomputations.
class GenerateUserFavoritesListsJob
  include Sidekiq::Job

  def perform(user_list_class_name = nil)
    failures = []

    subclasses_for(user_list_class_name).each do |klass|
      result = Services::Lists::GenerateUserFavorites.call(user_list_class: klass)

      if result.success?
        Rails.logger.info {
          "Generated #{klass.name} favorites list: #{result.data[:item_count]} items " \
            "from #{result.data[:ballot_count]} ballots"
        }
      else
        # Collected rather than raised, so one domain's failure still leaves the
        # other three regenerated.
        failures << "#{klass.name}: #{result.errors.join(", ")}"
        Rails.logger.error { "Failed to generate #{klass.name} favorites list: #{result.errors.join(", ")}" }
      end
    end

    raise "User favorites list generation failed -- #{failures.join("; ")}" if failures.any?
  end

  private

  def subclasses_for(name)
    return ::UserList.generating_subclasses if name.blank?

    klass = ::UserList.generating_subclasses.find { |candidate| candidate.name == name }
    raise ArgumentError, "#{name} is not a generating UserList subclass" if klass.nil?

    [klass]
  end
end
