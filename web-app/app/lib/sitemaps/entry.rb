module Sitemaps
  # One <url> in a child sitemap. path is host-relative ("/albums"); lastmod is
  # a Time or nil (static and filter pages carry none).
  Entry = Data.define(:path, :lastmod)
end
