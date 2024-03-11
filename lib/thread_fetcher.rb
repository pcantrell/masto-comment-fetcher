require "mastodon"
require_relative "mastodon_ext"

module ThreadFetcher
  def self.fetch_thread(root_post_id)
    client = Mastodon::REST::Client.new(
      base_url: 'https://hachyderm.io',
      bearer_token: (ENV["mastodon_api_token"] || raise("Missing env var: mastodon_api_token")),
      timeout: {
        connect: 4,
        read: 120,  # context request can take a while
        write: 20,
      },
    )

    root_post = client.status(root_post_id)

    # Why isn't this in the Mastodon API gem??
    context = client.perform_request_with_object(
      :get, "/api/v1/statuses/#{root_post_id}/context",
      {}, MastodonContext
    )

    [root_post] + context.descendants.to_a
  end
end
