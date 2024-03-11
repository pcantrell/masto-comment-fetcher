require "project"
require_relative "thread_fetcher"
require_relative "comment_processor"

module CommentFetcher
  def self.fetch_comments_for_blog(blog_name)
    project.data[blog_name].blog.posts.keys.each do |post_id|
      fetch_comments_for_post(blog_name, post_id)
    end
  end

  def self.fetch_comments_for_post(blog_name, post_id)
    puts "Fetching comments for #{blog_name} : #{post_id}"

    posts_dir = project.context.data_dir + blog_name + "blog.posts"
    unless posts_dir.directory?
      raise "Not a directory: #{posts_dir}"
    end

    post = project.data[blog_name].blog.posts[post_id]
    unless post
      raise "No post in #{blog_name} with id #{post_id.inspect}"
    end

    unless post.mastodon?
      puts "  (not a Mastodon post)"
      return
    end

    # `roots` is the IDs of all Mastodon statuses whose reply trees we consider to be comments on
    # the blog post itself.
    roots = [post.mastodon.post_id] + (post.mastodon.additional_comment_sources? || [])

    updated_comments = roots.flat_map do |masto_status_id|
      STDERR.puts "Fetching comments from #{masto_status_id}..."
      ThreadFetcher.fetch_thread(masto_status_id)
    end
    STDERR.puts "Found #{updated_comments.length} comments total"

    output_file = find_post_source(posts_dir, post).parent + "#{post.id}.comments.json"
    puts "Writing comments to #{output_file}"

    File.write(
      output_file,
      JSON.pretty_generate(
        CommentProcessor.create_comment_data(
          project,
          post,
          updated_comments,
          update_avatars: true
        )
      )
    )
  end

  def self.find_post_source(posts_dir, post)
    file_pattern = posts_dir + "*/#{post.id}.md"
    post_sources = Pathname.glob(file_pattern)
    unless post_sources.length == 1
      raise "Cannot locate unique source for blog post #{post.id.inspect}" +
        "\n  Searching for: #{file_pattern}" +
        "\n  Found: [#{post_sources.join(", ")}]"
    end
    post_sources.first
  end

  def self.project
    @project ||= begin
      result = Superfluous::Project.new(project_dir: Pathname.new(__dir__).parent.parent)
      result.read_data
      result
    end
  end
end

if ARGV == ["all"]
  %w(music teaching).each do |blog|
    CommentFetcher.fetch_comments_for_blog(blog)
  end
elsif ARGV.length == 2
  CommentFetcher.fetch_comments_for_post(ARGV[0], ARGV[1])
else
  STDERR.puts <<~_EOS_
    usage: fetch all
           fetch <blog_name> <post_id>
  _EOS_
end
