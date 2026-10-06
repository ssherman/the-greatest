# frozen_string_literal: true

class Lists::Wizard::MatchJob
  include Sidekiq::Job

  def perform(list_id)
    ::Services::Lists::Wizard::Core::StartMatch.call(list: ::List.find(list_id))
  end
end
