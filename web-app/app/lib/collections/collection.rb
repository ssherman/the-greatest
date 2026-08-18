module Collections
  # One curated collection of ranked items. Domain-neutral on purpose: `filter`
  # is an opaque payload that ONLY the owning domain's query object reads, which
  # is what lets a second domain register collections with a completely
  # different filter vocabulary and no change to this file.
  #
  # title_prefix lands directly after "The Greatest"; title_suffix lands last.
  # Both are optional and a collection normally sets exactly one.
  Collection = Struct.new(
    :domain, :slug, :name, :title_prefix, :title_suffix, :filter,
    keyword_init: true
  )
end
