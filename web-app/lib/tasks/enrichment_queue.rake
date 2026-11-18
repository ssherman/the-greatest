namespace :enrichment_queue do
  desc "Queue a fill of an enrichment queue (scope ranked or all, default ranked; limit optional): " \
    "bin/rails \"enrichment_queue:fill[books.origin,ranked,500]\""
  task :fill, [:kind, :scope, :limit] => :environment do |_task, args|
    usage = "Usage: bin/rails \"enrichment_queue:fill[kind,scope,limit]\" -- kind is one of " \
      "#{::Services::EnrichmentQueue::Registry.types.map(&:kind).join(", ")}; scope is ranked (default) or all; limit is optional"
    kind = args[:kind].to_s.strip
    abort usage if kind.empty? || ::Services::EnrichmentQueue::Registry.types.none? { |type| type.kind == kind }

    scope = args[:scope].to_s.strip.presence || "ranked"
    abort usage unless ::Services::EnrichmentQueue::Type::SCOPES.include?(scope)

    raw = args[:limit].to_s.strip
    limit = raw.empty? ? nil : Integer(raw, exception: false)
    abort usage if !raw.empty? && !limit&.positive?

    ::EnrichmentQueue::FillJob.perform_async(kind, scope, limit)
    puts "Queued EnrichmentQueue::FillJob for #{kind} (scope #{scope}#{", limit #{limit}" if limit}). Progress: the worker log."
  end
end
