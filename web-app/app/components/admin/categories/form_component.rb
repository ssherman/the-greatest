# frozen_string_literal: true

class Admin::Categories::FormComponent < ViewComponent::Base
  def initialize(category:, domain_config:)
    @category = category
    @domain_config = domain_config
  end

  private

  attr_reader :category, :domain_config

  def form_url
    if category.persisted?
      domain_config[:category_path_proc].call(category)
    else
      domain_config[:categories_path]
    end
  end

  def cancel_path
    form_url
  end

  def submit_label
    action = category.persisted? ? "Update" : "Create"
    "#{action} Category"
  end

  # A typeahead, not a <select>: books has 83k categories and a select of all
  # of them made the admin form unusable on production data.
  def parent_search_url
    domain_config.fetch(:categories_search_path)
  end

  def parent_selected_text
    category.parent&.name_with_type
  end
end
