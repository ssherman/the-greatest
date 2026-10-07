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
    if item
      fence_id = single_row ? nil : run_id
      # The check and the flag share the list lock, so a newer run cannot
      # re-mark the row between them.
      flagged = item.list.wizard_manager.fenced("match", fence_id) do
        fresh = ::ListItem.find_by(id: list_item_id)
        state = fresh && ::Services::Lists::Wizard::Core::RowState.new(fresh)
        if state&.pending?
          state.merge(::Services::Lists::Wizard::Core::MatchRow.failure_attributes(exception.message))
          state.flag!("match_failed")
        end
        true
      end
      ::Services::Lists::Wizard::Core::MatchProgress.call(list: item.list, single_row: single_row || false, run_id: fence_id) if flagged
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
