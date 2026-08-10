#!/usr/bin/env ruby
# frozen_string_literal: true

# probe_stores.rb - an independent check of what agent_sessions claims about disk.
#
# Run it on any machine with Ruby 2.5+ (the stock macOS ruby is enough; the gem
# itself needs 3.2+, this does not). It needs no gems, not even agent_sessions
# itself: every path claim is hardcoded in CLAIMS below, so what this prints is
# evidence the gem's own code did not produce. Paste the output back to an LLM (or
# into an issue) to see whether the promise still holds on that machine.
#
# It is read-only in the strongest sense available: it stats files and lists
# directories. It never opens a file, never reads a byte of content, and never
# shells out to another program.
#
#   ruby probe_stores.rb              # masked names (safe to paste)
#   ruby probe_stores.rb --reveal     # real names
#   ruby probe_stores.rb --deep       # raise the walk caps on huge stores
#   ruby probe_stores.rb --no-scan    # skip the unclaimed-candidate search

require "set"

# Deliberately written in old Ruby syntax so that it PARSES on the 2.6 that
# macOS still ships. A version check is useless if the file cannot be read: an
# endless method definition here would fail with "syntax error, unexpected '='"
# on a stranger's machine, which reads as "the script is broken", not "your Ruby
# is old". Everything below stays within Ruby 2.5.
if RUBY_VERSION < "2.5"
  abort "probe_stores.rb needs Ruby 2.5 or newer (this is #{RUBY_VERSION}). " \
        "Any modern Ruby works; the gem itself needs 3.2+."
end

SCRIPT_VERSION = "1.0"
CLAIMS_SOURCE = "agent_sessions 0.2 adapter declarations (lib/agent_sessions/adapters/*.rb)"

# What the gem promises. Transcribed by hand from the adapter DSL so that a gem
# bug cannot hide behind this script agreeing with it. `env_join` mirrors the DSL:
# XDG_DATA_HOME is a parent, so the agent's own directory is appended to it, while
# CODEX_HOME replaces the base outright.
CLAIMS = [
  {
    agent: "claude", label: "Claude Code", documented: "yes", verified_on: "2026-08-05",
    base: { default: "~/.claude", env: "CLAUDE_CONFIG_DIR" },
    stores: [
      { kind: "projects", dir: "projects", glob: "*/*.jsonl", format: "jsonl", required: true,
        note: "the glob is meant to miss <id>/subagents/ and <id>/tool-results/: those are one " \
              "session's sidecar files, not sessions of their own. Their bytes count toward the " \
              "parent session, so unmatched files here are expected, not drift." },
      { kind: "history", file: "history.jsonl", format: "jsonl", required: false }
    ]
  },
  {
    agent: "codex", label: "Codex CLI", documented: "no", verified_on: "2026-07-21",
    base: { default: "~/.codex", env: "CODEX_HOME" },
    stores: [
      { kind: "sessions", dir: "sessions", glob: "*/*/*/rollout-*.jsonl", format: "jsonl", required: true },
      { kind: "archived", dir: "archived_sessions", glob: "rollout-*.jsonl", format: "jsonl", required: false,
        note: "flat, unlike sessions/YYYY/MM/DD/. Enumerated as real sessions since 0.2.0." },
      { kind: "history", file: "history.jsonl", format: "jsonl", required: false },
      { kind: "index", file: "session_index.jsonl", format: "jsonl", required: false }
    ]
  },
  {
    agent: "cursor", label: "Cursor CLI", documented: "no", verified_on: "2026-07-21",
    base: { default: "~/.cursor" },
    stores: [
      { kind: "chats", dir: "chats", glob: "*/*/store.db", format: "sqlite", required: true },
      { kind: "acp_sessions", dir: "acp-sessions", format: "json", required: false }
    ]
  },
  {
    agent: "cursor_ide", label: "Cursor IDE", documented: "no", verified_on: "2026-07-21",
    base: { default: "~/.cursor" },
    stores: [
      { kind: "transcripts", dir: "projects", glob: "*/agent-transcripts/*", format: "unknown", required: true }
    ]
  },
  {
    agent: "amp", label: "Amp CLI", documented: "partly", verified_on: "2026-07-21",
    base: { default: "~/.local/share/amp", env: "XDG_DATA_HOME", env_join: "amp" },
    stores: [
      { kind: "threads", dir: "threads", glob: "T-*.json", format: "json", required: true },
      { kind: "secrets", file: "secrets.json", format: "json", required: false }
    ]
  },
  {
    agent: "opencode", label: "opencode", documented: "partly", verified_on: "2026-07-21",
    base: { default: "~/.local/share/opencode", env: "XDG_DATA_HOME", env_join: "opencode" },
    stores: [
      { kind: "database", file: "opencode.db", format: "sqlite", required: true },
      { kind: "legacy", dir: "storage", format: "json", required: false }
    ]
  },
  {
    agent: "pi", label: "pi", documented: "yes", verified_on: "2026-07-21",
    base: { default: "~/.pi/agent", env: "PI_CODING_AGENT_DIR" },
    stores: [
      { kind: "sessions", dir: "sessions", glob: "--*--/*.jsonl", format: "jsonl",
        env: "PI_CODING_AGENT_SESSION_DIR", required: true }
    ]
  }
].freeze

# Paths no adapter declares but that are suspected of holding real sessions. A hit
# here is counter-evidence: the gem would under-report for that agent.
SUSPECTS = [
  { agent: "cursor_ide", path: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
    note: "believed to be where Cursor IDE agent sessions really live (table cursorDiskKV)" },
  { agent: "cursor_ide", path: "~/.config/Cursor/User/globalStorage/state.vscdb",
    note: "Linux equivalent of the same suspected store" },
  { agent: "claude", path: "~/.claude/todos", note: "sibling state; not a transcript store, listed for shape only" },
  { agent: "amp", path: "~/Library/Application Support/amp", note: "macOS-native location the XDG default would miss" },
  { agent: "opencode", path: "~/Library/Application Support/opencode",
    note: "macOS-native location the XDG default would miss" }
].freeze

# The gem's audit knows the first five. Anything flagged from the rest is a gap in
# the "audits whether transcripts sit inside anything that syncs" promise.
SYNC_ROOTS = {
  "dropbox" => { roots: ["~/Dropbox"], known_to_gem: true },
  "icloud" => { roots: ["~/Library/Mobile Documents"], known_to_gem: true },
  "cloud_storage" => { roots: ["~/Library/CloudStorage"], known_to_gem: true },
  "onedrive" => { roots: ["~/OneDrive"], known_to_gem: true },
  "google_drive" => { roots: ["~/Google Drive", "~/Google Drive (My Drive)"], known_to_gem: true },
  "nextcloud" => { roots: ["~/Nextcloud", "~/ownCloud"], known_to_gem: false },
  "syncthing" => { roots: ["~/Sync"], known_to_gem: false },
  "pcloud" => { roots: ["~/pCloud Drive"], known_to_gem: false },
  "mega" => { roots: ["~/MEGA"], known_to_gem: false },
  "box" => { roots: ["~/Box", "~/Box Sync"], known_to_gem: false },
  "proton_drive" => { roots: ["~/Proton Drive"], known_to_gem: false }
}.freeze

# Where an undeclared agent store might be hiding, and what an agent directory
# tends to be called. The scan is deliberately name-based: it is looking for
# layouts this script does not know, so it cannot look for a known shape.
SCAN_ROOTS = ["~", "~/.config", "~/.local/share", "~/.local/state",
              "~/Library/Application Support", "~/AppData/Roaming", "~/AppData/Local"].freeze
# Matched against whole name tokens, never as a substring: "amp" inside
# "examples" and "pi" inside "pip" both flagged unrelated directories.
AGENT_WORDS = Set.new(%w[
  claude codex cursor amp opencode copilot gemini aider goose cline continue windsurf
  zed crush droid factory qwen kiro antigravity junie augment openhands devin codebuff
  pi ampcode anthropic openai
]).freeze
SCAN_SKIP = Set.new(["Cache", "Caches", "Code Cache", "GPUCache", "CachedData", "DawnCache",
                     "node_modules", "blob_storage", "Service Worker", "Crashpad", "logs",
                     "extensions", "Local Storage", "IndexedDB", "Session Storage"]).freeze

# Tokens kept verbatim when masking: they are layout, not content. Every other
# word in a name is somebody's project or machine, and becomes an opaque <w>.
SHAPE_LITERALS = Set.new(%w[
  rollout store db meta session sessions thread threads history index part chat chats
  agent agents transcripts projects project storage opencode cursor claude codex amp pi
  secrets auth config cache data state global main default log logs tmp temp lock
  backup bak old new archive archived todos messages message parts snapshot snapshots
  subagents tool results scratchpad shell checkpoints worktrees plugins commands skills
  hooks ide statsig files blobs attachments exports transcript
  json jsonl sqlite vscdb wal shm ndjson md txt yml yaml toml csv db3
]).freeze

UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
HOME = Dir.home

options = {
  reveal: ARGV.include?("--reveal"),
  deep: ARGV.include?("--deep"),
  scan: !ARGV.include?("--no-scan")
}

if ARGV.include?("--help") || ARGV.include?("-h")
  banner = File.readlines(__FILE__).drop(3).take_while { |line| line.start_with?("#") }
  puts banner.map { |line| line.sub(/\A#\s?/, "") }
  exit
end

MAX_ENTRIES = options[:deep] ? 200_000 : 25_000
MAX_DEPTH = options[:deep] ? 12 : 8
SHAPES_SHOWN = options[:deep] ? 40 : 10
CANDIDATES_SHOWN = options[:deep] ? 200 : 15

# --- helpers ----------------------------------------------------------------

def expand(path)
  File.expand_path(path)
end

def display(path)
  return path unless path.start_with?(HOME)

  path.sub(HOME, "~")
end

def presence(value)
  value && !value.empty? ? value : nil
end

def bytes(count)
  units = ["B", "KB", "MB", "GB", "TB"]
  size = count.to_f
  unit = 0
  while size >= 1024 && unit < units.size - 1
    size /= 1024
    unit += 1
  end
  unit.zero? ? "#{count} B" : format("%.1f %s", size, units[unit])
end

def age(time)
  return "?" unless time

  seconds = Time.now - time
  return "in the future" if seconds.negative?
  return "#{(seconds / 60).round}m ago" if seconds < 3600
  return "#{(seconds / 3600).round}h ago" if seconds < 86_400
  return "#{(seconds / 86_400).round}d ago" if seconds < 86_400 * 400

  format("%.1fy ago", seconds / (86_400 * 365.25))
end

def stamp(time)
  time ? time.strftime("%Y-%m-%d %H:%M") : "?"
end

# Wraps a claim note under a fixed label, so a long explanation stays inside
# the same column as everything else the store prints.
def wrap(text, label, width = 96)
  indent = " " * label.length
  words = text.split(" ")
  lines = [label.dup]
  words.each do |word|
    if lines.last.length + word.length + 1 > width && lines.last.strip != label.strip
      lines << indent.dup
    end
    lines.last << (lines.last.end_with?(" ") ? "" : " ") << word
  end
  lines
end

def plural(count, word, many = nil)
  "#{count} #{count == 1 ? word : (many || "#{word}s")}"
end

# Mirrors AgentSessions::Location#files: the path is escaped, the glob never is.
def escape_glob(path)
  path.gsub(/[\{}\[\]*?]/) { |char| "\#{char}" }
end

# A run of unrecognized words collapses to one <words>: their number and length
# are the caller's project names, and a shape table that keeps them turns one
# layout into one row per project, burying the layout it exists to show.
def mask_name(name, reveal:)
  return name if reveal

  masked = name.gsub(UUID, "<uuid>").split(/([-_. ])/).map { |token| mask_token(token) }.join
  masked.gsub(/<w>(?:[-_. ]<w>)+/, "<words>")
end

# Digits are masked before anything else, including the short-token passthrough:
# a bare "08" left verbatim splits one date-stamped layout into one shape per
# calendar day, which buries the pattern the glob is being judged against.
def mask_token(token)
  return token if token.start_with?("<")
  return "#" * [token.length, 12].min if token.match?(/\A\d+\z/)
  return "<hex#{token.length}>" if token.match?(/\A\h+\z/) && token.length >= 8
  return token if SHAPE_LITERALS.include?(token.downcase)
  return token if token.length <= 2 && !token.match?(/\d/)

  # A timestamp fragment like "05T09" is structure, not content: masking its
  # digits while keeping the one-or-two letter separators loses nothing private.
  if token.match?(/\A[\dA-Za-z]+\z/) && token.match?(/\d/) &&
     token.scan(/[A-Za-z]+/).all? { |run| run.length <= 2 }
    return token.gsub(/\d+/) { |run| "#" * run.length }
  end

  "<w>"
end

def mask_path(rel, reveal:)
  rel.split("/").map { |part| mask_name(part, reveal: reveal) }.join("/")
end

def real_path(path)
  File.realpath(path)
rescue SystemCallError
  nil
end

def sync_services_for(path)
  real = real_path(path) || path
  SYNC_ROOTS.map do |service, config|
    hit = config[:roots].any? do |root|
      expanded = real_path(expand(root))
      expanded && (real == expanded || real.start_with?("#{expanded}/"))
    end
    next unless hit

    config[:known_to_gem] ? service : "#{service} (NOT in the gem's SYNC_ROOTS)"
  end.compact
end

# --- bounded directory walk -------------------------------------------------

# Files found under a root, with the caps that stopped it. Symlinked directories
# are counted and not followed: a loop would otherwise hang a probe someone else
# is running on their machine for us.
Tree = Struct.new(:files, :dirs, :symlinks, :truncated, :errors, keyword_init: true) do
  def total_bytes
    files.sum(&:size)
  end
  def newest
    files.map(&:mtime).max
  end
  def oldest
    files.map(&:mtime).min
  end
  def max_depth
    files.map { |file| file.rel.count("/") + 1 }.max || 0
  end
end
Entry = Struct.new(:rel, :size, :mtime)

def walk(root, max_entries: MAX_ENTRIES, max_depth: MAX_DEPTH, skip: Set.new)
  tree = Tree.new(files: [], dirs: 0, symlinks: 0, truncated: false, errors: [])
  queue = [[root, "", 0]]

  catch(:capped) do
    until queue.empty?
      abs, rel, depth = queue.shift
      children = begin
        Dir.children(abs)
      rescue SystemCallError => e
        tree.errors << "#{display(abs)}: #{e.class.name.split("::").last}"
        next
      end

      children.sort.each do |name|
        child = File.join(abs, name)
        child_rel = rel.empty? ? name : "#{rel}/#{name}"
        stat = begin
          File.lstat(child)
        rescue SystemCallError
          next
        end

        if stat.symlink?
          tree.symlinks += 1
        elsif stat.directory?
          tree.dirs += 1
          next if skip.include?(name)

          if depth + 1 <= max_depth
            queue << [child, child_rel, depth + 1]
          else
            tree.truncated = true
          end
        elsif stat.file?
          tree.files << Entry.new(child_rel, stat.size, stat.mtime)
          if tree.files.size >= max_entries
            tree.truncated = true
            throw :capped
          end
        end
      end
    end
  end

  tree
end

# --- probing a claim --------------------------------------------------------

def resolve_base(claim, env)
  config = claim[:base]
  override = presence(config[:env] && env[config[:env]])
  return expand(config[:default]) unless override

  expand(config[:env_join] ? File.join(override, config[:env_join]) : override)
end

def resolve_store(base, store, env)
  override = presence(store[:env] && env[store[:env]])
  return expand(override) if override

  File.join(base, store[:dir] || store[:file])
end

def probe_store(path, store, reveal:)
  result = { path: path, kind: store[:kind], required: store[:required], format: store[:format],
             glob: store[:glob], note: store[:note], single_file: !store[:file].nil?, sync: [] }

  unless File.exist?(path)
    result[:state] = :missing
    return result
  end

  result[:sync] = sync_services_for(path)

  if File.file?(path)
    stat = File.stat(path)
    result[:state] = :file
    result[:size] = stat.size
    result[:mtime] = stat.mtime
    return result
  end

  unless File.directory?(path)
    result[:state] = :other
    return result
  end

  result[:state] = :dir
  result[:tree] = walk(path)
  result[:matched], result[:matched_dirs] = matched_rels(path, store[:glob])
  result[:shapes] = shapes_for(result[:tree], result[:matched], reveal: reveal)
  result
end

# The gem's glob, run the gem's way, so the counts are directly comparable.
# Directory hits are counted apart from file hits: a glob that resolves to
# directories (cursor_ide's "*/agent-transcripts/*" would, if the transcripts
# were themselves directories) reports matches while enumerating no sessions.
def matched_rels(root, glob)
  return [nil, 0] unless glob

  prefix = "#{root}/"
  files = Set.new
  dirs = 0
  Dir.glob(File.join(escape_glob(root), glob)).each do |hit|
    File.directory?(hit) ? dirs += 1 : files << hit.delete_prefix(prefix)
  end
  [files, dirs]
rescue SystemCallError
  [Set.new, 0]
end

# Groups every file under the store by its masked relative path, then reports how
# many of each group the declared glob caught. A group with 0 of N caught is the
# layout the gem is missing, spelled out in the shape of its own filenames.
def shapes_for(tree, matched, reveal:)
  groups = Hash.new { |hash, key| hash[key] = { total: 0, matched: 0 } }
  tree.files.each do |file|
    group = groups[mask_path(file.rel, reveal: reveal)]
    group[:total] += 1
    group[:matched] += 1 if matched&.include?(file.rel)
  end
  groups.sort_by { |shape, counts| [-counts[:total], shape] }
end

def verdict_for(stores)
  return ["NOT INSTALLED", "no declared store exists here"] if stores.none? { |s| s[:state] != :missing }

  missing = stores.select { |s| s[:required] && s[:state] == :missing }
  unless missing.empty?
    return ["LAYOUT DRIFT", "required store #{missing.map { |s| s[:kind] }.join(", ")} " \
                            "is absent while other declared stores exist"]
  end

  blind = stores.select do |store|
    store[:glob] && store[:state] == :dir && store[:matched].empty? && store[:tree].files.any?
  end
  unless blind.empty?
    return ["GLOB MISS", "#{blind.map { |s| s[:kind] }.join(", ")} holds files but the declared " \
                         "glob matched none of them"]
  end

  empty = stores.select { |s| s[:glob] && s[:state] == :dir && s[:tree].files.empty? }
  return ["PASS (EMPTY)", "declared stores exist; #{empty.map { |s| s[:kind] }.join(", ")} holds no files"] if empty.any?

  ["PASS", "declared stores exist and the declared globs match files"]
end

# --- unclaimed candidates ---------------------------------------------------

def claimed_paths(probes)
  probes.flat_map { |probe| [probe[:base]] + probe[:stores].map { |store| store[:path] } }.uniq
end

# A three-letter word only counts when it is the whole name: "pi" as one token
# among several flags ~/.sonic-pi, and "amp" flags anything with "amp" in it.
def agentish?(name)
  tokens = name.downcase.split(/[^a-z0-9]+/).reject(&:empty?)
  tokens.any? do |token|
    next false unless AGENT_WORDS.include?(token)

    token.length > 3 || tokens.size == 1
  end
end

def candidate_dirs(claimed)
  seen = Set.new
  SCAN_ROOTS.map { |root| expand(root) }.each_with_object([]) do |root, found|
    next unless File.directory?(root)

    children = begin
      Dir.children(root)
    rescue SystemCallError
      next
    end

    children.sort.each do |name|
      next unless agentish?(name)

      path = File.join(root, name)
      next unless File.directory?(path)
      next if seen.include?(path)
      next if claimed.any? { |claim| path == claim || path.start_with?("#{claim}/") || claim.start_with?("#{path}/") }

      seen << path
      found << path
    end
  end
end

def extension_histogram(tree)
  counts = Hash.new(0)
  tree.files.each { |file| counts[File.extname(file.rel).downcase.delete_prefix(".")] += 1 }
  counts.sort_by { |ext, count| [-count, ext] }.first(5)
       .map { |ext, count| "#{count} .#{ext.empty? ? "(none)" : ext}" }.join(", ")
end

# --- report -----------------------------------------------------------------

out = []
env = ENV
probes = CLAIMS.map do |claim|
  base = resolve_base(claim, env)
  stores = claim[:stores].map do |store|
    probe_store(resolve_store(base, store, env), store, reveal: options[:reveal])
  end
  { claim: claim, base: base, stores: stores }
end

out << "AGENT SESSION STORE PROBE v#{SCRIPT_VERSION}"
out << "generated  #{Time.now.strftime("%Y-%m-%d %H:%M %z")}"
out << "host       #{RUBY_PLATFORM}, ruby #{RUBY_VERSION}"
out << "claims     #{CLAIMS_SOURCE}"
out << "method     stat + directory listing only. No file was opened or read. No program was executed."
out << if options[:reveal]
         "names      REVEALED (--reveal): real file and directory names are printed below."
       else
         "names      masked: <w> = one unrecognized word, <words> = a run of them, #### = digits, " \
           "<hexN>/<uuid> = ids,\n           known layout words kept verbatim. Re-run with --reveal for real names."
       end
out << "caps       walk stops at #{MAX_ENTRIES} files or depth #{MAX_DEPTH} per store" \
       "#{" (--deep in effect)" if options[:deep]}"
out << ""

out << "== ENVIRONMENT OVERRIDES =="
%w[CLAUDE_CONFIG_DIR CODEX_HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
   PI_CODING_AGENT_DIR PI_CODING_AGENT_SESSION_DIR].each do |name|
  value = presence(env[name])
  out << format("  %-28s %s", name, value ? display(value) : "(unset)")
end
out << "  note: the gem honours CLAUDE_CONFIG_DIR, CODEX_HOME, XDG_DATA_HOME (amp, opencode),"
out << "        PI_CODING_AGENT_DIR, PI_CODING_AGENT_SESSION_DIR. It deliberately ignores"
out << "        XDG_CONFIG_HOME for Cursor. XDG_STATE_HOME is listed only as context."
out << ""

probes.each do |probe|
  claim = probe[:claim]
  config = claim[:base]
  source = if presence(config[:env] && env[config[:env]])
             "from #{config[:env]}#{" + /#{config[:env_join]}" if config[:env_join]}"
           elsif config[:env]
             "default; #{config[:env]} unset"
           else
             "default; no env override exists"
           end

  out << "== #{claim[:agent]} (#{claim[:label]}) =="
  out << "  claims documented=#{claim[:documented]}, last verified #{claim[:verified_on]}"
  out << "  base   #{display(probe[:base])}  [#{source}]  -> #{File.directory?(probe[:base]) ? "exists" : "MISSING"}"

  probe[:stores].each do |store|
    label = "#{store[:kind]} (#{store[:required] ? "required" : "optional"}, #{store[:format]})"
    out << "  store  #{label}"
    out << "         path    #{display(store[:path])}"
    out << "         glob    #{store[:glob] ? store[:glob].inspect : "(none declared)"}"
    wrap(store[:note], "         claim   ").each { |line| out << line } if store[:note]

    case store[:state]
    when :missing
      out << "         result  MISSING#{store[:required] ? "  <- required by the claim" : ""}"
      next
    when :file
      out << "         result  file, #{bytes(store[:size])}, modified #{stamp(store[:mtime])} (#{age(store[:mtime])})"
      out << "         note    declared as a single file; nothing to glob" if store[:single_file]
    when :other
      out << "         result  exists but is neither a file nor a directory"
      next
    when :dir
      tree = store[:tree]
      out << "         result  dir, #{plural(tree.files.size, "file")} in #{plural(tree.dirs, "dir")}, " \
             "#{bytes(tree.total_bytes)}, max depth #{tree.max_depth}"
      if store[:glob]
        out << "         matched #{store[:matched].size} of #{plural(tree.files.size, "file")} " \
               "matched the declared glob"
        if store[:matched_dirs].positive?
          out << "         warn    the glob also matched " \
                 "#{plural(store[:matched_dirs], "directory", "directories")} - directories are not sessions"
        end
      else
        out << "         matched (no glob declared - the gem cannot enumerate this store)"
      end
      if tree.files.any?
        out << "         newest  #{stamp(tree.newest)} (#{age(tree.newest)})   oldest #{stamp(tree.oldest)}"
        out << "         shapes  count  glob?  #{options[:reveal] ? "relative path" : "masked relative path"}"
        store[:shapes].first(SHAPES_SHOWN).each do |shape, counts|
          verdict = if store[:glob].nil? then "n/a"
                    elsif counts[:matched] == counts[:total] then "yes"
                    elsif counts[:matched].zero? then "NO"
                    else "#{counts[:matched]}/#{counts[:total]}"
                    end
          out << format("                 %5d  %-5s  %s", counts[:total], verdict, shape)
        end
        hidden = store[:shapes].size - SHAPES_SHOWN
        out << "                 ... #{hidden} more distinct shapes not shown" if hidden.positive?
      end
      out << "         limits  walk was CAPPED - counts are lower bounds" if tree.truncated
      out << "         limits  #{tree.symlinks} symlinks skipped (not followed)" if tree.symlinks.positive?
      tree.errors.first(3).each { |error| out << "         error   #{error}" }
    end

    out << "         sync    #{store[:sync].join(", ")}  <- plaintext transcripts inside a sync folder" if store[:sync].any?
  end

  status, why = verdict_for(probe[:stores])
  out << "  VERDICT #{status}: #{why}"
  out << ""
end

out << "== SUSPECTED PATHS THE GEM DOES NOT CLAIM =="
SUSPECTS.each do |suspect|
  path = expand(suspect[:path])
  unless File.exist?(path)
    out << format("  absent   %-58s [%s]", display(suspect[:path]), suspect[:agent])
    next
  end

  detail = if File.directory?(path)
             tree = walk(path, max_entries: 5_000, max_depth: 4, skip: SCAN_SKIP)
             "dir, #{plural(tree.files.size, "file")}, #{bytes(tree.total_bytes)}, newest #{stamp(tree.newest)} " \
               "(#{age(tree.newest)}), types: #{extension_histogram(tree)}"
           else
             stat = File.stat(path)
             "file, #{bytes(stat.size)}, modified #{stamp(stat.mtime)} (#{age(stat.mtime)})"
           end
  out << "  PRESENT  #{display(suspect[:path])}  [#{suspect[:agent]}]"
  out << "           #{detail}"
  out << "           why it matters: #{suspect[:note]}"
  sync = sync_services_for(path)
  out << "           sync: #{sync.join(", ")}" if sync.any?
end
out << ""

if options[:scan]
  out << "== UNCLAIMED AGENT-LOOKING DIRECTORIES =="
  out << "  Name-based scan of #{SCAN_ROOTS.map { |root| display(expand(root)) }.join(", ")}."
  out << "  Anything listed here is a directory whose name looks like a coding agent's and that"
  out << "  no adapter claims. Most are config, not transcripts - judge by the file types."
  # Most recently written first: a directory touched today is a live store worth
  # arguing about, one last written two years ago is an abandoned install.
  candidates = candidate_dirs(claimed_paths(probes))
                 .map { |path| [path, walk(path, max_entries: 5_000, max_depth: 4, skip: SCAN_SKIP)] }
                 .reject { |_path, tree| tree.files.empty? }
                 .sort_by { |_path, tree| -tree.newest.to_i }

  if candidates.empty?
    out << "  (none found)"
  else
    candidates.first(CANDIDATES_SHOWN).each do |path, tree|
      out << "  #{display(path)}"
      out << "    #{plural(tree.files.size, "file")}#{" (walk capped)" if tree.truncated}, " \
             "#{bytes(tree.total_bytes)}, newest #{stamp(tree.newest)} (#{age(tree.newest)})"
      out << "    types: #{extension_histogram(tree)}"
    end
    hidden = candidates.size - CANDIDATES_SHOWN
    out << "  ... #{hidden} older candidates not shown (--deep lists them)" if hidden.positive?
  end
  out << ""
end

out << "== HOW TO READ THIS =="
out << "  GLOB MISS      strongest evidence a path claim is stale: the declared directory exists"
out << "                 and holds files, but the declared glob matched none of them. Compare the"
out << "                 shapes table against the glob - the shapes are what is actually on disk."
out << "  LAYOUT DRIFT   some declared stores exist, a required one does not. The agent writes"
out << "                 here, so the missing store most likely moved rather than never existed."
out << "  NOT INSTALLED  nothing declared exists. This proves nothing about the claim: the agent"
out << "                 was probably never run on this machine. Check the unclaimed list anyway."
out << "  PASS (EMPTY)   the store is there and empty. Fine on a fresh install, suspicious on a"
out << "                 machine the agent is used on daily - that combination suggests the real"
out << "                 sessions are written somewhere else."
out << "  partial glob   a shapes row reading '3/7' means the glob caught some files in that shape"
out << "                 but not all - usually a depth or extension the pattern half-covers."
out << "  sync           a store inside a sync folder means plaintext transcripts leave the machine."
out << "                 A service tagged 'NOT in the gem's SYNC_ROOTS' is one its audit misses."
out << ""
out << "  Ask the LLM to compare CLAIMED path/glob against the OBSERVED shapes for every agent"
out << "  whose verdict is not NOT INSTALLED, and to propose the corrected glob where they differ."

puts out.join("\n")
