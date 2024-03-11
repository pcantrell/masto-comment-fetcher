require "mastodon"

class Mastodon::Status
  def content=(new_content)
    @attributes["content"] = new_content
  end

  attr_accessor :prune
end

class MastodonContext < Mastodon::Base
  collection_attr_reader :ancestors, Mastodon::Status
  collection_attr_reader :descendants, Mastodon::Status
end
