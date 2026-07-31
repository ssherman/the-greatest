# frozen_string_literal: true

# Path-based pagination (/page/2) instead of query strings (?page=2).
#
# Opt-in: only active when a :page_path option is supplied, so every caller that
# does not pass one keeps pagy's stock query-string behaviour untouched.
module Pagy::PathBasedPaging
  def compose_url(absolute, path, params, fragment)
    builder = @options[:page_path]
    return super unless builder

    page = params.delete(@options[:page_key] || "page")
    query = Pagy::Linkable::QueryUtils.build_nested_query(params).sub(/\A(?=.)/, "?")
    "#{@request.base_url if absolute}#{builder.call(page)}#{query}#{fragment}"
  end

  # pagy composes one templated URL containing PAGE_TOKEN and string-splits it per
  # page. That makes a page-1 special case ("/" rather than "/page/1") impossible to
  # express, and PAGE_TOKEN.to_i is 0, which corrupts the template. Build each href
  # for real instead; the templating is only a speed optimisation and is irrelevant
  # for a nav of a handful of anchors.
  def a_lambda(anchor_string: @options[:anchor_string], **options)
    return super unless @options[:page_path]

    lambda do |page, text = page_label(page), classes: nil, aria_label: nil|
      rel = case page
      when @previous then %( rel="prev")
      when @next then %( rel="next")
      end

      %(<a href="#{compose_page_url(page, **options)}"#{
        %( #{anchor_string}) if anchor_string}#{
        %( class="#{classes}") if classes}#{rel}#{
        %( aria-label="#{aria_label}") if aria_label}>#{text}</a>)
    end
  end
end

Pagy::Offset.prepend(Pagy::PathBasedPaging)
