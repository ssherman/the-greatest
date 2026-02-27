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

  def parent_categories
    domain_config[:model_class].active.where.not(id: category.id).sorted_by_name
  end
end
