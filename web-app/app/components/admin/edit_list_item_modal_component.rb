# frozen_string_literal: true

class Admin::EditListItemModalComponent < ViewComponent::Base
  def initialize(list_item:)
    @list_item = list_item
    @list = list_item.list
  end

  def item_display_name
    return unverified_item_display_name if @list_item.listable.nil?

    if @list_item.listable.respond_to?(:title)
      @list_item.listable.title
    elsif @list_item.listable.respond_to?(:name)
      @list_item.listable.name
    else
      "#{@list_item.listable.class.name} ##{@list_item.listable.id}"
    end
  end

  def unverified_item_display_name
    if @list_item.metadata.present?
      @list_item.metadata["title"] || @list_item.metadata["name"] || "Unverified Item ##{@list_item.position}"
    else
      "Unverified Item ##{@list_item.position}"
    end
  end

  def metadata_json
    return "" if @list_item.metadata.blank?
    JSON.pretty_generate(@list_item.metadata)
  end
end
