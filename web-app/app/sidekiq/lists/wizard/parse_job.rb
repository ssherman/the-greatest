# frozen_string_literal: true

class Lists::Wizard::ParseJob
  include Sidekiq::Job

  def perform(list_id)
    list = ::List.find(list_id)
    ::Services::Lists::Wizard::Core::ParseRows.call(list: list, adapter: ::Services::Lists::Wizard::Core::Adapters.for(list))
  end
end
