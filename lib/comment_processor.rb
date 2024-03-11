require "mastodon"
require "nokogiri"
require "pathname"
require "json"
require "mime/types"
require "mini_magick"
require_relative "core_ext"
require_relative "mastodon_ext"

module CommentProcessor
  def self.create_comment_data(project, post, updated_thread, update_avatars: true)

    # Turn flat status list from Mastodon API in a reply tree
    tree = StatusTree.new
    updated_thread.each do |status|
      tree.add(status)
    end

    reestablish_prunings(post, tree)

    self.update_avatars(project, tree.all_statuses) if update_avatars

    result = gather_comments(tree, tree.roots)
    result[post.mastodon.post_id]["prune"] = "self"
    result
  end

private

  def self.reestablish_prunings(post, tree)
    # The site administrator can manually remove comments by settingt the "prune" attribute to
    # either "self" or "subtree". This script fully recreates the comment tree, and we want to
    # preserve those "prune" attributes through the refresh.
    #
    # By the time the existing blog data arrives, the data transformer has already removed comment
    # nodes with "prune" attributes; however, it tracks the removed comments in the "prunings" attr
    # of the parent post.

    tree.all_statuses.each do |status|
      status.prune ||= post.prunings[status.id]
    end
  end

  def self.update_avatars(project, statuses)
    avatar_urls = {}
    statuses.each do |status|
      avatar_urls[status.account.id] = status.account.avatar_static
    end

    avatar_urls.lazy
      .map { |id, url| [id, URI(url)] }
      .group_by { |id, uri| uri + "/" }
      .each do |server, uris|
        HTTP.persistent(server) do |http|
          uris.each do |account_id, uri|
            next if uri.path =~ /missing\.\w+$/

            avatar_dir = project.context.data_dir + "avatars/mastodon" + account_id
            avatar_dir.mkdir unless avatar_dir.exist?
            meta_file = avatar_dir + "_.json"
            raw_image_file = Dir[avatar_dir + "raw.*"].first

            meta = if meta_file.exist? && raw_image_file
              JSON.load_file(meta_file)
            else
              {}
            end

            STDERR.print "Fetching avatar for #{account_id}: #{uri.path} → #{avatar_dir} ..."
            STDERR.flush

            resp = http.get(uri.path, headers: { "If-None-Match": meta["etag"] })
            if resp.status.not_modified?
              STDERR.puts "not modified"
              resp.body.to_s  # read empty body so next request can proceed
            else
              STDERR.puts "#{resp.body.to_s.bytesize} bytes"
              raw_ext = MIME::Types[resp.content_type.mime_type].first.preferred_extension
              raw_image_file = avatar_dir + "raw.#{raw_ext}"
              File.write(raw_image_file, resp.body)
              File.write(meta_file, { etag: resp.headers["etag"] }.to_json)
            end

            [["80x80", "webp"]].each do |size, format|
              image = MiniMagick::Image.open(raw_image_file)
              image.resize(size)
              image.format(format)
              outfile = avatar_dir + "sizes.#{size}.#{format}"
              image.write(outfile)
              File.chmod(0644, outfile)  # MiniMagick writes images with 600 perms for some nonsense reason
            end
          end
        end
      end
  end

  def self.gather_comments(tree, statuses)
    Hash[
      statuses.map do |status|
        next unless %w(public unlisted).include?(status.visibility)
        [
          status.id,
          remove_empty_values(
            {
              name: status.account.display_name,
              url: status.account.url,
              timestamp: status.created_at,
              mastodon_account_id: status.account.id,
              comment_url: status.url,
              prune: status.prune,
              content: clean_content(status.content),
              replies: gather_comments(tree, tree.children_for(status)),
            }
          )
        ]
      end.compact
    ]
  end

  def self.remove_empty_values(hash)
    Hash[
      hash.map do |k, v|
        [k, v] unless v.empty?
      end.compact
    ]
  end

  def self.clean_content(content)
    doc = Nokogiri::HTML.fragment("<div>" + content + "</div>")

    # Remove @mentions that appear at the start of a reply (but preserve interstitial ones)
    doc.css('.h-card').each do |node|
      all_blank_before =
        Enumerator
          .produce(node, &:previous_sibling)
          .take_while { |node| !node.nil? }
          .drop(1)
          .all? { |node| node.to_s.blank? || node.to_s == "<br>" }

      if all_blank_before
        node.remove
      end
    end

    # Mastodon adds noisy HTML to govern formatting in reply lists, tight spaces, etc.
    # We don't need it.
    doc.css('.invisible, .ellipsis').each { |n| n.replace(n.children) }

    doc.children.first.children.to_s
      .gsub(%r{(<a [^>]+>\s*https?://[^/]+/[^<]{16})[^<]+(</a>)}, "\\1…\\2")  # Trim long links
      .gsub(%r{<p>(\s*<br/?>)+}, "<p>")    # Strip extra line breaks
      .gsub(%r{(<br/?>\s*)+</p>}, "</p>")
      .gsub(%r{<p>\d+/\d*</p>}, "")        # Strip thread numbering (e.g. "3/" and "3/5")
      .gsub(%r{<br>\s*\d+/\d*}, "")
      .gsub(%r{\s*<p>\s*</p>\s*}, "")      # Strip empty paragraphs
      .strip
      .gsub(/\s+/, " ")
  end

  # Indexing and collation for a collection of maybe-connected Masto statuses
  class StatusTree
    def initialize
      @status_by_id = {}
      @children_by_id = Hash.new { |h,k| h[k] = [] }
    end

    def add(status)
      parent = @status_by_id[status.in_reply_to_id]
      if parent && parent.account.id == status.account.id  # fold threaded replies into single posts
        parent.content += status.content
        @status_by_id[status.id] = parent
        return
      end

      @status_by_id[status.id] = status
      @children_by_id[parent&.id] << status
    end

    def [](id)
      @status_by_id[id]
    end

    def all_statuses
      @status_by_id.values
    end

    def roots
      @children_by_id[nil]  # NB: will not work if a reply post is a starting point
    end

    def children_for(parent)
      @children_by_id[parent.id]
    end
  end
end
