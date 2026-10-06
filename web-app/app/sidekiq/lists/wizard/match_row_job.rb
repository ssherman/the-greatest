# frozen_string_literal: true

class Lists::Wizard::MatchRowJob
  include Sidekiq::Job

  # Five retries (hours, not the default weeks) before the row is flagged.
  sidekiq_options retry: 5

  # Out of retries: flag the row so the step can finish instead of staying
  # "running" for good (which would block every wizard action).
  sidekiq_retries_exhausted do |msg, exception|
    list_item_id, single_row, _attempt = msg["args"]
    item = ::ListItem.find_by(id: list_item_id)
    if item
      state = ::Services::Lists::Wizard::Core::RowState.new(item)
      if state.pending?
        state.merge(::Services::Lists::Wizard::Core::MatchRow.failure_attributes(exception.message))
        state.flag!("match_failed")
      end
      ::Services::Lists::Wizard::Core::MatchProgress.call(list: item.list, single_row: single_row || false)
    end
  end

  def perform(list_item_id, single_row = false, attempt = 1)
    item = ::ListItem.find_by(id: list_item_id)
    return if item.nil?

    ::Services::Lists::Wizard::Core::MatchRow.call(
      list_item: item, adapter: ::Services::Lists::Wizard::Core::Adapters.for(item.list), single_row: single_row, attempt: attempt
    )
  end
end
