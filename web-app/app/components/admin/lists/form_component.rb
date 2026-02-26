# frozen_string_literal: true

class Admin::Lists::FormComponent < ViewComponent::Base
  include Admin::ListsHelper

  def initialize(list:, domain_config:)
    @list = list
    @domain_config = domain_config
  end

  private

  attr_reader :list, :domain_config

  def form_url
    if list.persisted?
      domain_config[:list_path_proc].call(list)
    else
      domain_config[:lists_path]
    end
  end

  def cancel_path
    form_url
  end

  def submit_label
    action = list.persisted? ? "Update" : "Create"
    "#{action} #{domain_config[:item_label]} List"
  end

  def error_noun
    "#{domain_config[:item_label].downcase} list"
  end

  def show_musicbrainz_field?
    domain_config[:extra_fields].include?(:musicbrainz_series_id)
  end
end
