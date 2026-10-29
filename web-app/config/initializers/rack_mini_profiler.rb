# Development only (the gem is in the development group).
#
# rack-mini-profiler rewrites the ETag of every response it wraps, so in development
# /user_list_state could never answer a conditional request with a 304 and the
# browser-cache re-check path went untested locally. The endpoint is JSON the page
# never renders, so there is nothing to profile on it.
if defined?(Rack::MiniProfiler)
  Rack::MiniProfiler.config.skip_paths ||= []
  Rack::MiniProfiler.config.skip_paths << "/user_list_state"
end
