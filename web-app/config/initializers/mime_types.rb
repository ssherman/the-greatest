# Rack does not know .webmanifest, so public/icons/books/site.webmanifest would be
# served as text/plain. ActionDispatch::Static looks types up here.
Rack::Mime::MIME_TYPES[".webmanifest"] = "application/manifest+json"
