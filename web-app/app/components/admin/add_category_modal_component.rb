# frozen_string_literal: true

class Admin::AddCategoryModalComponent < ViewComponent::Base
  def initialize(item:)
    @item = item
  end

  def form_url
    Admin::DomainRouting.category_items_path_for(@item)
  end

  def search_url
    if Admin::DomainRouting.domain_for(@item) == :games
      helpers.search_admin_games_categories_path
    else
      helpers.search_admin_categories_path
    end
  end

  def item_type_label
    @item.class.name.demodulize.downcase
  end
end
