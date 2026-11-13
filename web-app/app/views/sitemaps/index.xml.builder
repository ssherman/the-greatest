xml.instruct!
xml.sitemapindex xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  @sources.each do |source|
    lastmod = source.lastmod
    (1..Sitemaps::Registry.page_count(source)).each do |page|
      xml.sitemap do
        xml.loc "#{@base_url}/sitemaps/#{source.key}-#{page}.xml"
        xml.lastmod lastmod.iso8601 if lastmod
      end
    end
  end
end
