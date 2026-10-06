# frozen_string_literal: true

class Lists::Wizard::MatchJob
  include Sidekiq::Job

  # A failure is a failed step; the admin's retry starts a new run id.
  sidekiq_options retry: false

  def perform(list_id, run_id = nil)
    ::Services::Lists::Wizard::Core::StartMatch.call(list: ::List.find(list_id), run_id: run_id)
  end
end
