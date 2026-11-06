# Runs the workflow recovery sweep once a minute (config/schedule.yml). retry: 0
# because the next minute's sweep is the retry, and a Sidekiq retry of a sweep
# would only overlap it.
class WorkflowRecoveryJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 0

  def perform
    counts = Workflows::Recovery.call
    return if counts.values.all?(&:zero?)

    Rails.logger.info("WorkflowRecoveryJob: " + counts.map { |name, count| "#{name}=#{count}" }.join(" "))
  end
end
