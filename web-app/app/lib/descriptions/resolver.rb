module Descriptions
  class Resolver
    def self.call(descriptions, kind: :summary, locale: "en")
      candidates = descriptions.select do |description|
        !description.deprecated? &&
          description.kind == kind.to_s &&
          description.locale == locale.to_s
      end
      return nil if candidates.empty?

      pool = candidates.select(&:preferred?)
      pool = candidates if pool.empty?
      pool.min_by { |description| SourcePriority::ORDER.index(description.source) || SourcePriority::ORDER.size }
    end
  end
end
