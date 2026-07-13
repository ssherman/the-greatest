# frozen_string_literal: true

class Admin::AddItemToListModalComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
    @config = Admin::DomainRouting.list_config(list) || {}
  end

  def autocomplete_url
    @config[:autocomplete_path]
  end

  def expected_listable_type
    @config[:listable_type]
  end

  def item_label
    @config.fetch(:item_label, "Item")
  end
end
