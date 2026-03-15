#!/usr/bin/env ruby

# frozen_string_literal: true

require "date"
require "etc"
require "net/http"
require "optparse"
require "pathname"
require "set"
require "thread"
require "uri"
require "yaml"

class PostLinkChecker
  LinkOccurrence = Struct.new(:source, :line, :url, keyword_init: true)
  Result = Struct.new(:status, :detail, keyword_init: true)

  DEFAULT_TIMEOUT = 10
  DEFAULT_REDIRECT_LIMIT = 5
  DEFAULT_CONCURRENCY = [Etc.nprocessors, 8].min
  SITE_CONFIG_PATH = File.expand_path("../_config.yml", __dir__)
  DEFAULT_POSTS_DIR = File.expand_path("../_posts", __dir__)

  def initialize(posts_dir: DEFAULT_POSTS_DIR, timeout: DEFAULT_TIMEOUT, concurrency: DEFAULT_CONCURRENCY)
    @posts_dir = File.expand_path(posts_dir)
    @timeout = timeout
    @concurrency = [concurrency.to_i, 1].max
    @site_url = load_site_url
    @known_post_paths = build_known_post_paths
    @dead_links = []
    @warnings = []
  end

  def run
    links = collect_links
    external_links, internal_links = links.partition { |link| external_link?(link.url) }

    check_internal_links(internal_links)
    check_external_links(external_links)

    print_report
    @dead_links.empty? ? 0 : 1
  end

  private

  def load_site_url
    return nil unless File.exist?(SITE_CONFIG_PATH)

    config = YAML.safe_load_file(SITE_CONFIG_PATH, permitted_classes: [], aliases: false) || {}
    url = config["url"].to_s.strip
    url.empty? ? nil : url.sub(%r{/$}, "")
  rescue StandardError
    nil
  end

  def build_known_post_paths
    paths = Set.new

    post_files.each do |path|
      front_matter = read_front_matter(path)
      permalink = front_matter["permalink"].to_s.strip
      slug = File.basename(path, File.extname(path)).sub(/^\d{4}-\d{2}-\d{2}-/, "")
      permalink = "/posts/#{slug}/" if permalink.empty?
      normalized = normalize_internal_path(permalink)
      next unless normalized

      paths << normalized
      paths << normalized.sub(%r{/$}, "") unless normalized == "/"
      paths << File.join(normalized, "index.html") if normalized.end_with?("/")
    end

    paths
  end

  def post_files
    Dir.glob(File.join(@posts_dir, "*.md")).sort
  end

  def read_front_matter(path)
    content = File.read(path)
    match = content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
    return {} unless match

    YAML.safe_load(match[1], permitted_classes: [Date, Time], aliases: false) || {}
  rescue StandardError
    {}
  end

  def collect_links
    post_files.flat_map do |path|
      extract_links(path)
    end
  end

  def extract_links(path)
    lines = File.readlines(path, chomp: true)
    definitions = extract_reference_definitions(lines)
    occurrences = []

    lines.each_with_index do |line, index|
      line_number = index + 1
      occurrences.concat(extract_inline_links(path, line, line_number))
      occurrences.concat(extract_reference_links(path, line, line_number, definitions))
      occurrences.concat(extract_html_links(path, line, line_number))
      occurrences.concat(extract_autolinks(path, line, line_number))
    end

    occurrences.uniq { |link| [link.source, link.line, link.url] }
  end

  def extract_reference_definitions(lines)
    definitions = {}

    lines.each do |line|
      next unless (match = line.match(/^\s*\[([^\]]+)\]:\s+(\S+)/))

      definitions[match[1].strip.downcase] = match[2].strip
    end

    definitions
  end

  def extract_inline_links(path, line, line_number)
    scan_urls(line, /(?<!!)\[[^\]]+\]\(([^)\s]+)(?:\s+"[^"]*")?\)/, path, line_number)
  end

  def extract_reference_links(path, line, line_number, definitions)
    links = []

    line.scan(/(?<!!)\[([^\]]+)\]\[([^\]]*)\]/) do |text, ref|
      next if text.start_with?("^")

      key = (ref.empty? ? text : ref).strip.downcase
      url = definitions[key]
      next unless url

      links << LinkOccurrence.new(source: relative_path(path), line: line_number, url: url)
    end

    links
  end

  def extract_html_links(path, line, line_number)
    scan_urls(line, /href=["']([^"']+)["']/, path, line_number)
  end

  def extract_autolinks(path, line, line_number)
    scan_urls(line, /<((?:https?:\/\/|\/)[^>]+)>/, path, line_number)
  end

  def scan_urls(line, pattern, path, line_number)
    links = []
    line.scan(pattern) do |match|
      url = Array(match).first.to_s.strip
      next if skip_url?(url)

      links << LinkOccurrence.new(source: relative_path(path), line: line_number, url: url)
    end
    links
  end

  def skip_url?(url)
    url.empty? || url.start_with?("#", "mailto:", "tel:", "javascript:")
  end

  def external_link?(url)
    uri = URI.parse(url)
    return false unless uri.is_a?(URI::HTTP)

    !internal_site_uri?(uri)
  rescue URI::InvalidURIError
    false
  end

  def internal_site_uri?(uri)
    return true if uri.host.nil?
    return false unless @site_url

    uri.host == URI.parse(@site_url).host
  rescue URI::InvalidURIError
    false
  end

  def check_internal_links(links)
    links.each do |link|
      normalized = normalize_internal_target(link.url)
      next if normalized.nil?
      next if @known_post_paths.include?(normalized)

      @dead_links << [link, "post not found: #{normalized}"]
    rescue URI::InvalidURIError
      @dead_links << [link, "invalid internal URL"]
    end
  end

  def normalize_internal_target(url)
    uri = URI.parse(url)
    return nil if uri.scheme && !internal_site_uri?(uri)

    path = uri.path.to_s
    return nil if path.empty?
    return nil unless path.include?("/posts/") || path.start_with?("posts/", "/posts/")

    normalize_internal_path(path)
  end

  def normalize_internal_path(path)
    return nil if path.nil? || path.empty?

    normalized = path.start_with?("/") ? path : "/#{path}"
    normalized = normalized.gsub(%r{/+}, "/")
    normalized = normalized.sub(%r{/$}, "") unless normalized == "/" || normalized.end_with?("/")
    normalized
  end

  def check_external_links(links)
    unique_urls = links.map(&:url).uniq
    queue = Queue.new
    unique_urls.each { |url| queue << url }
    results = {}
    mutex = Mutex.new

    workers = Array.new([@concurrency, unique_urls.size].min) do
      Thread.new do
        loop do
          url = queue.pop(true)
          result = check_external_url(url)
          mutex.synchronize { results[url] = result }
        rescue ThreadError
          break
        end
      end
    end

    workers.each(&:join)

    links.each do |link|
      result = results.fetch(link.url)
      case result.status
      when :dead
        @dead_links << [link, result.detail]
      when :warning
        @warnings << [link, result.detail]
      end
    end
  end

  def check_external_url(url, redirect_limit: DEFAULT_REDIRECT_LIMIT)
    uri = URI.parse(url)
    return Result.new(status: :dead, detail: "invalid URL") unless uri.is_a?(URI::HTTP)

    response = perform_request(uri, Net::HTTP::Head)
    if response.nil? || response.code.to_i == 405
      response = perform_request(uri, Net::HTTP::Get)
    end

    return classify_http_response(response, url, redirect_limit) if response

    Result.new(status: :warning, detail: "no response")
  rescue URI::InvalidURIError
    Result.new(status: :dead, detail: "invalid URL")
  rescue StandardError => e
    Result.new(status: :warning, detail: e.message)
  end

  def perform_request(uri, request_class)
    request = request_class.new(uri)
    request["User-Agent"] = "post-link-checker/1.0"

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @timeout, read_timeout: @timeout) do |http|
      http.request(request)
    end
  end

  def classify_http_response(response, url, redirect_limit)
    code = response.code.to_i

    case code
    when 200..399
      if response.is_a?(Net::HTTPRedirection)
        return Result.new(status: :warning, detail: "redirect limit exceeded") if redirect_limit <= 0

        location = response["location"]
        return Result.new(status: :warning, detail: "redirect without location") if location.to_s.empty?

        redirected = URI.join(url, location).to_s
        return check_external_url(redirected, redirect_limit: redirect_limit - 1)
      end

      Result.new(status: :ok, detail: nil)
    when 401, 403, 429
      Result.new(status: :warning, detail: "HTTP #{code}")
    else
      Result.new(status: :dead, detail: "HTTP #{code}")
    end
  end

  def print_report
    if @dead_links.empty? && @warnings.empty?
      puts "No dead links found in #{relative_path(@posts_dir)}/."
      return
    end

    unless @dead_links.empty?
      puts "Dead links:"
      @dead_links.each do |link, detail|
        puts "- #{link.source}:#{link.line} #{link.url} (#{detail})"
      end
    end

    unless @warnings.empty?
      puts if @dead_links.any?
      puts "Warnings:"
      @warnings.each do |link, detail|
        puts "- #{link.source}:#{link.line} #{link.url} (#{detail})"
      end
    end
  end

  def relative_path(path)
    Pathname.new(path).relative_path_from(Pathname.new(File.expand_path("..", __dir__))).to_s
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    posts_dir: ENV.fetch("POST_LINK_POSTS_DIR", PostLinkChecker::DEFAULT_POSTS_DIR),
    timeout: ENV.fetch("POST_LINK_TIMEOUT", PostLinkChecker::DEFAULT_TIMEOUT).to_i,
    concurrency: ENV.fetch("POST_LINK_CONCURRENCY", PostLinkChecker::DEFAULT_CONCURRENCY).to_i
  }

  OptionParser.new do |parser|
    parser.banner = "Usage: ruby tools/check_post_links.rb [options]"

    parser.on("-d", "--posts-dir PATH", "Directory containing markdown posts") do |value|
      options[:posts_dir] = value
    end

    parser.on("-t", "--timeout SECONDS", Integer, "HTTP timeout per request") do |value|
      options[:timeout] = value
    end

    parser.on("-c", "--concurrency COUNT", Integer, "Concurrent external link checks") do |value|
      options[:concurrency] = value
    end
  end.parse!

  exit PostLinkChecker.new(**options).run
end
