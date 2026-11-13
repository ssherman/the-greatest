xml.instruct!
xml.sitemapindex xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  size = Sitemaps::Registry.page_size
  @sources.each do |source|
    lastmod = source.lastmod
    pages = [(source.count / size.to_f).ceil, 1].max
    (1..pages).each do |page|
      xml.sitemap do
        xml.loc "#{@base_url}/sitemaps/#{source.key}-#{page}.xml"
        xml.lastmod lastmod.iso8601 if lastmod
      end
    end
  end
end
