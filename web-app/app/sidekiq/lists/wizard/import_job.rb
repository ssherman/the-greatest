# frozen_string_literal: true

class Lists::Wizard::ImportJob
  include Sidekiq::Job

  # A failure is a failed step; the admin's retry starts a new run id.
  sidekiq_options retry: false

  def perform(list_id, run_id = nil)
    list = ::List.find(list_id)
    ::Services::Lists::Wizard::Core::ImportRows.call(list: list, adapter: ::Services::Lists::Wizard::Core::Adapters.for(list), run_id: run_id)
  end
end
