module DomainHelper
  def domain_specific_asset_path(asset_name)
    case current_domain
    when :music
      asset_path("music/#{asset_name}")
    when :movies
      asset_path("movies/#{asset_name}")
    when :games
      asset_path("games/#{asset_name}")
    else
      asset_path(asset_name)
    end
  end

  # The JavaScript bundle for the current domain's public site, e.g. "books-web".
  # Bundle names come from config/asset_bundles.json; the pairing between a
  # domain layout and its bundle is enforced by
  # test/lint/asset_bundle_coverage_test.rb, because Propshaft raises on a
  # missing asset and that would be a 500 on every page of the site.
  def domain_js_bundle
    "#{current_domain}-web"
  end

  def domain_specific_layout
    domain_settings[:layout]
  end

  def domain_name
    domain_settings[:name]
  end

  def domain_color_scheme
    domain_settings[:color_scheme]
  end

  def domain_specific_class(base_class)
    "#{base_class} #{base_class}--#{current_domain}"
  end

  def domain_specific_meta_tags
    {
      title: domain_name,
      description: "Discover the greatest #{current_domain} of all time",
      keywords: "#{current_domain}, entertainment, media, the greatest"
    }
  end
end
