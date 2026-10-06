# frozen_string_literal: true

class Lists::Wizard::MatchRowJob
  include Sidekiq::Job

  def perform(list_item_id, single_row = false)
    item = ::ListItem.find_by(id: list_item_id)
    return if item.nil?

    ::Services::Lists::Wizard::Core::MatchRow.call(
      list_item: item, adapter: ::Services::Lists::Wizard::Core::Adapters.for(item.list), single_row: single_row
    )
  end
end
