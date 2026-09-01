# frozen_string_literal: true

module Viaf
  # VIAF's JSON is a mechanical translation of XML, so every key carries a
  # namespace prefix. The prefix is not stable: cluster fetches use "ns1:",
  # search results increment per result ("ns2:", "ns3:"), and BriefVIAF uses
  # "v:". Anything matching only /^ns\d+:/ will silently miss the last case.
  module Normalizer
    module_function

    def call(object)
      case object
      when Hash
        object.each_with_object({}) { |(key, value), acc| acc[strip_prefix(key)] = call(value) }
      when Array
        object.map { |element| call(element) }
      else
        object
      end
    end

    def array(value)
      case value
      when nil then []
      when Array then value
      else [value]
      end
    end

    def strip_prefix(key)
      key_string = key.to_s
      return key_string if key_string.start_with?("xmlns")
      return key_string unless key_string.include?(":")

      key_string.split(":", 2).last
    end
  end
end
