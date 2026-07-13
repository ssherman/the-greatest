# frozen_string_literal: true

class Admin::AddCategoryModalComponent < ViewComponent::Base
  def initialize(item:)
    @item = item
  end

  def form_url
    Admin::DomainRouting.category_items_path_for(@item)
  end

  def search_url
    Admin::DomainNav.config_for(Admin::DomainRouting.domain_for(@item))&.dig(:categories_search_path) ||
      helpers.search_admin_categories_path
  end

  def item_type_label
    @item.class.name.demodulize.downcase
  end
end
