xml.instruct!
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  @entries.each do |entry|
    xml.url do
      xml.loc "#{@base_url}#{entry.path}"
      xml.lastmod entry.lastmod.iso8601 if entry.lastmod
    end
  end
end
