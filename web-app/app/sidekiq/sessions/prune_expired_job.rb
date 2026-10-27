class Sessions::PruneExpiredJob
  include Sidekiq::Job

  # delete_all: Session has no callbacks and nothing depends on them.
  def perform
    Session.expired.delete_all
  end
end
