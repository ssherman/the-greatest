# frozen_string_literal: true

class Lists::Wizard::MatchRowJob
  include Sidekiq::Job

  # Five retries (hours, not the default weeks) before the row is flagged.
  sidekiq_options retry: 5

  # Out of retries: flag the row so the step can finish instead of staying
  # "running" for good (which would block every wizard action). A full-match
  # job of a superseded run flags nothing: its rows belong to the newer run.
  sidekiq_retries_exhausted do |msg, exception|
    list_item_id, single_row, _attempt, run_id = msg["args"]
    item = ::ListItem.find_by(id: list_item_id)
    if item && (single_row || item.list.wizard_manager.run_current?("match", run_id))
      state = ::Services::Lists::Wizard::Core::RowState.new(item)
      if state.pending?
        state.merge(::Services::Lists::Wizard::Core::MatchRow.failure_attributes(exception.message))
        state.flag!("match_failed")
      end
      ::Services::Lists::Wizard::Core::MatchProgress.call(list: item.list, single_row: single_row || false, run_id: single_row ? nil : run_id)
    end
  end

  # run_id is the match generation a full-match job belongs to; a single-row
  # re-match carries none (its row's "still pending" re-read is its fence).
  def perform(list_item_id, single_row = false, attempt = 1, run_id = nil)
    item = ::ListItem.find_by(id: list_item_id)
    return if item.nil?

    ::Services::Lists::Wizard::Core::MatchRow.call(
      list_item: item, adapter: ::Services::Lists::Wizard::Core::Adapters.for(item.list), single_row: single_row, attempt: attempt,
      run_id: run_id
    )
  end
end
