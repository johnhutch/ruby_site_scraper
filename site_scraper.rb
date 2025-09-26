require "faraday" # easy http fetches
require "nokogiri" # parses html
require "addressable/uri" # lets us work with URLs
require "fileutils" # lets us write shit to disk
require "mime/types" # helps us figure out what kinda file we're looking at
require "openssl" # download shit in parallel to speed up parsing. I THINK this worked? see line 92 or so. 

ASSET_BUCKET   = "_assets"  # where hashed assets go under OUT_DIR
# prevent crashes due to overly long cachbuster-y filenames. 
MAX_SEG_LEN    = 200        # set max chars per filename segment
MAX_PATH_LEN   = 240        # set max chars for full path on local
ASSET_MAP      = {}         # original_url (normalized) -> local asset path (site-root absolute)

ORIGIN        = "https://www.swiftkickweb.com" 
OUT_DIR       = "mirror"
MAX_PAGES     = 5000
ASSET_EXTS    = %w[.css .js .png .jpg .jpeg .gif .webp .avif .svg .ico .woff .woff2 .ttf .eot .mp4 .webm .pdf]
HTML_CTYPES   = ["text/html", "application/xhtml+xml"]
ASSET_HOSTS   = [/^static\d*\.squarespace\.com$/i] # mirror CDN too

# Simple frontier data structure to keep track of fetched URLs vs to-be-fetched URLs. With de-dupe, natch. 
class Frontier
  def initialize; @q = []; @seen = {}; end
  def push(u); k = canon(u); @q << k unless @seen[k]; end
  def pop; u = @q.shift; @seen[u] = true; u; end
  def any?; !@q.empty?; end
  def seen?(u); @seen.key?(canon(u)); end
  private def canon(u); Addressable::URI.parse(u).normalize.to_s; end
end

# connected to all the things.
def conn
  @conn ||= Faraday.new do |f|
    f.headers["User-Agent"] = "ruby-static-mirror/1.0"
    f.follow_redirects = true if f.respond_to?(:follow_redirects=)
  end
end

# makes sure we don't scrape code provided from other sites. On one hand, this keeps scrapes
# mangeable. On the other hand, it prevented scraping google font files and  have to file/replace
# those. So.... not... sure how best to improve or replace this with something a bit smarter. 
def same_site?(uri)
  u = Addressable::URI.parse(uri)
  o = Addressable::URI.parse(ORIGIN)
  u.scheme == o.scheme && u.host == o.host
end

# check to see if this is an asset file (css, js, image bin, etc)  or an html file we can crawl
def asset_like?(uri)
  path = Addressable::URI.parse(uri).path
  ext  = File.extname(path.to_s).downcase
  return true if ASSET_EXTS.include?(ext)
  host = Addressable::URI.parse(uri).host
  return true if host && ASSET_HOSTS.any? { |rx| host.match?(rx) }
  false
end

# prevent my name-too-big errors. probably isn't an issue on most sites. sqsp was a headache 
# cause of their CDN asset paths. got this from AI. seems to work ok. 
def path_is_too_long?(abs_path)
  # crude but effective: guard both segment and total path length
  return true if abs_path.bytesize > MAX_PATH_LEN
  File.basename(abs_path).bytesize > MAX_SEG_LEN
end

# get a safe short filename in case it's one of those sqsp biggins
def hashed_asset_basename(url)
  u   = Addressable::URI.parse(url)
  ext = File.extname(u.path.to_s).downcase
  digest = OpenSSL::Digest::SHA256.hexdigest(url)
  # todo: include some kinda tiny hint about the original cause debugging this sucked
  base_hint = File.basename(u.path.to_s, ".*")[0, 12] # check the first 12 chars
  hint = base_hint && !base_hint.empty? ? "#{base_hint}-" : ""
  "#{hint}#{digest}#{ext}"
end

# figure out where to put the danged file (locally).
# Slightly AI modified to deal with the FILENAME SO BIG issue
def asset_local_site_path(url)
  # Return a site-root-absolute path (e.g. "/_assets/ab/cd/<hash>.ext")
  return ASSET_MAP[url] if ASSET_MAP.key?(url)

  u = Addressable::URI.parse(url)
  ext = File.extname(u.path.to_s).downcase
  # Try keeping original CDN path under OUT_DIR first:
  raw_path = File.join(OUT_DIR, u.path)
  if !path_is_too_long?(raw_path)
    site_path = u.path # site-root absolute
  else
    # Generate a short hashed path
    digest = OpenSSL::Digest::SHA256.hexdigest(url)
    shard1, shard2 = digest[0,2], digest[2,2]
    base = hashed_asset_basename(url)
    site_path = "/#{ASSET_BUCKET}/#{shard1}/#{shard2}/#{base}"
  end

  ASSET_MAP[url] = site_path
  site_path
end

# little fn for writing the local path for non-html files
def local_fs_path_from_site_path(site_path)
  File.join(OUT_DIR, site_path)
end

# litt fn for getting and writing the local path for HTML files
def local_path_for_html(url)
  u = Addressable::URI.parse(url)
  path = u.path
  path = "/" if path.nil? || path.empty?
  path = path.end_with?("/") ? path : "#{path}/"
  File.join(OUT_DIR, path, "index.html")
end

# little fn for getting & setting the local path before writing
def local_path_for_asset(url)
  site_path = asset_local_site_path(url)
  local_fs_path_from_site_path(site_path)
end

# before we do the local path things above, figure out if it's an asset or html
def local_path_for(url)
  if asset_like?(url)
    local_path_for_asset(url)
  else
    local_path_for_html(url)
  end
end

# don't dump shit into non-existent dirs, ya dingus
def ensure_dir(path)
  FileUtils.mkdir_p(File.dirname(path))
end

# save images and fonts and junk
def save_binary(path, body)
  ensure_dir(path)
  File.binwrite(path, body)
end

#save html and junk
def save_text(path, body)
  ensure_dir(path)
  File.write(path, body)
end

# go get the thing
def fetch(url)
  resp = conn.get(url)
  [resp.status, resp.headers, resp.body]
rescue => e
  warn "Fetch error #{url}: #{e}"
  [599, {}, ""]
end

# turns relative paths into absolute paths to make sure we fetch actual fetchable URLs and
# not relative URLs which, y'know, are relative. like ../images/image.jpg. which won't work.
def absolute(base, href)
  return nil if href.nil? || href.strip.empty? || href.start_with?("#", "mailto:", "tel:")
  Addressable::URI.join(base, href).to_s
rescue
  nil
end

# convert the absolute URL back into a relative URL when writing back into the code (after fetching)
# so our html code isn't full of absolute urls that point to file:/// or example.com or whatever.
def to_site_root_absolute(url)
  # rewrite to site-root absolute (e.g. /about/) for portability
  u = Addressable::URI.parse(url)
  u.query = nil if !asset_like?(url) # drop queries for html pages
  u.scheme = nil; u.host = nil
  u.to_s
end

# figure out what the rewritten path (handling assets and html separately) should look like
# inside the mirrored/local file
def rewrite_to_local(url, base_url)
  # For assets, rewrite to the (possibly hashed) site path.
  if asset_like?(url)
    return asset_local_site_path(url)
  else
    # For HTML pages, keep site-root absolute, drop query
    u = Addressable::URI.parse(url)
    u.query = nil
    u.scheme = nil; u.host = nil
    u.to_s
  end
end

# parse the HTML, fine the links, do the things
# uses my favorite pain-in-the-ass-to-install gem nokogiri to crawl the things
def extract_links(html, base_url)
  doc = Nokogiri::HTML.parse(html)
  urls = []

  doc.css("a[href]").each do |a|
    abs = absolute(base_url, a["href"]); next unless abs
    urls << abs
    a["href"] = rewrite_to_local(abs, base_url)
  end

  doc.css("link[href]").each do |ln|
    abs = absolute(base_url, ln["href"]); next unless abs
    urls << abs
    ln["href"] = rewrite_to_local(abs, base_url)
  end

  doc.css("img[src], source[src], video[src], audio[src]").each do |el|
    if el["src"]
      abs = absolute(base_url, el["src"]); if abs
        urls << abs
        el["src"] = rewrite_to_local(abs, base_url)
      end
    end
    if el["srcset"]
      newset = el["srcset"].split(",").map(&:strip).map do |part|
        url_part, *rest = part.split(/\s+/)
        abs = absolute(base_url, url_part)
        if abs
          urls << abs
          "#{rewrite_to_local(abs, base_url)} #{rest.join(' ')}".strip
        else
          part
        end
      end.join(", ")
      el["srcset"] = newset
    end
  end

  doc.css("script[src]").each do |s|
    abs = absolute(base_url, s["src"]); next unless abs
    urls << abs
    s["src"] = rewrite_to_local(abs, base_url)
  end

  [doc.to_html, urls.uniq]
end

# pretty self explanatory. 
def is_html?(headers, url, body)
  ct = headers["content-type"] || headers["Content-Type"] || ""
  if ct.empty?
    # Heuristic: treat as HTML if it looks like HTML
    return body.lstrip.start_with?("<!DOCTYPE", "<html", "<HTML")
  end
  HTML_CTYPES.any? { |h| ct.downcase.start_with?(h) }
end

# main function that ties all of the above together. I.e., the thing
# that gets fired first that starts all this off. 
def mirror
  frontier = Frontier.new
  # Seed with home and sitemap
  frontier.push(ORIGIN)
  frontier.push(Addressable::URI.join(ORIGIN, "/sitemap.xml").to_s)

  pages_fetched = 0

  while frontier.any? && pages_fetched < MAX_PAGES
    url = frontier.pop
    next unless url
    status, headers, body = fetch(url)
    pages_fetched += 1
    puts "[#{pages_fetched}] #{status} #{url}"

    next unless status.between?(200, 299)

    # Is this sitemap?
    if File.basename(Addressable::URI.parse(url).path) =~ /sitemap.*\.xml/i
      begin
        doc = Nokogiri::XML(body)
        doc.remove_namespaces!
        doc.xpath("//loc").each do |loc|
          loc_url = loc.text.strip
          # Only crawl same-site HTML endpoints from sitemap
          frontier.push(loc_url) if same_site?(loc_url)
        end
      rescue => e
        warn "Sitemap parse failed: #{e}"
      end
      # save the xml too
      save_binary(local_path_for(url), body)
      next
    end

    # Decide HTML vs asset
    if is_html?(headers, url, body) && same_site?(url)
      processed_html, outgoing = extract_links(body, url)
      save_text(local_path_for(url), processed_html)

      outgoing.each do |out|
        # enqueue assets from CDN + same-site pages
        if asset_like?(out)
          frontier.push(out)
        else
          frontier.push(out) if same_site?(out)
        end
      end
    else
      # Asset or offsite: only mirror if asset-like (CDN, fonts, etc.)
      if asset_like?(url)
        save_binary(local_path_for(url), body)
      end
    end
  end
end

mirror
puts "Mirror complete in ./#{OUT_DIR}"

