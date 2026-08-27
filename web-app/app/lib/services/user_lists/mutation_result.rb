module Services
  module UserLists
    MutationResult = Struct.new(:success?, :data, :errors, keyword_init: true)
  end
end
