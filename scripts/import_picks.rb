#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Import a week's picks from the Google Sheet into _data/weeks.yml.
#
#   bundle exec ruby scripts/import_picks.rb              # latest week in weeks.yml
#   bundle exec ruby scripts/import_picks.rb --week 3
#   bundle exec ruby scripts/import_picks.rb --new-week   # append the next week, then import
#   bundle exec ruby scripts/import_picks.rb --dry-run
#
# The sheet is read through the public gviz CSV endpoint, addressed by tab name
# rather than gid, because the gid changes every week. headers=1 is required:
# without it gviz guesses the header row and merges data rows into it.
#
# Picks that have already been graded are never overwritten.

require 'yaml'
require 'csv'
require 'cgi'
require 'optparse'
require 'typhoeus'
require 'zlib'

ROOT        = File.expand_path('..', __dir__)
DATA_FILE   = File.join(ROOT, '_data', 'weeks.yml')
CONFIG_FILE = File.join(ROOT, '_config.yml')

SHEET_ID = ENV.fetch('PARLAY_SHEET_ID', '11-hSfWJREgTgrnIS_w80s_qeDVoz25vs13giojqvVkk')

FINAL_STATUSES = %w[won lost ai_won ai_lost].freeze

options = { dry_run: false, week: nil, new_week: false }
OptionParser.new do |o|
  o.banner = 'Usage: import_picks.rb [options]'
  o.on('--week N', Integer, 'Week to import (default: latest in weeks.yml)') { |v| options[:week] = v }
  o.on('--new-week', 'Append the next week before importing') { options[:new_week] = true }
  o.on('--dry-run', 'Report what would change without writing') { options[:dry_run] = true }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!

# A pick is "not made yet" if it is empty or a placeholder.
def blank_pick?(value)
  s = value.to_s.strip
  s.empty? || s.match?(/\A_+\z/) || s.match?(/\A-+\z/) || s.casecmp?('none')
end

# The sheet is inconsistent about the leading + on positive American odds.
def normalize_odds(raw)
  s = raw.to_s.strip
  return '' if s.empty?
  s.match?(/\A\d+\z/) ? "+#{s}" : s
end

def blank_picks_for(players)
  players.each_with_object({}) do |p, acc|
    acc[p['id']] = { 'pick' => '___', 'status' => 'pending', 'worst' => false, 'odds' => '' }
  end
end

# gviz's fallback behavior for an unknown sheet= name is NOT a reliable 404:
# on this spreadsheet it silently serves a leftover hidden tab from a past
# season instead of an HTML error. So tab existence is decided beforehand by
# sheet_names (an authoritative list from the workbook itself), and fetch_tab
# is only ever called with a name already confirmed to exist.
def fetch_tab(name)
  url = "https://docs.google.com/spreadsheets/d/#{SHEET_ID}/gviz/tq" \
        "?tqx=out:csv&headers=1&sheet=#{CGI.escape(name)}"
  res = Typhoeus.get(url, followlocation: true, timeout: 30)
  return nil unless res.success?

  body = res.body.to_s
  return nil if body.strip.empty?
  return nil if body.lstrip.start_with?('<')

  body
end

# Extract one file's bytes from a zip archive already in memory. Just enough
# of the zip format to read xl/workbook.xml out of an xlsx export - not a
# general-purpose unzip.
def zip_entry(data, path)
  eocd_pos = data.rindex("PK\x05\x06")
  return nil unless eocd_pos

  cd_size   = data[eocd_pos + 12, 4].unpack1('V')
  cd_offset = data[eocd_pos + 16, 4].unpack1('V')

  pos = cd_offset
  while pos < cd_offset + cd_size
    break unless data[pos, 4] == "PK\x01\x02"

    method       = data[pos + 10, 2].unpack1('v')
    comp_size    = data[pos + 20, 4].unpack1('V')
    name_len     = data[pos + 28, 2].unpack1('v')
    extra_len    = data[pos + 30, 2].unpack1('v')
    comment_len  = data[pos + 32, 2].unpack1('v')
    local_offset = data[pos + 42, 4].unpack1('V')
    name         = data[pos + 46, name_len]

    if name == path
      lh_name_len  = data[local_offset + 26, 2].unpack1('v')
      lh_extra_len = data[local_offset + 28, 2].unpack1('v')
      data_start   = local_offset + 30 + lh_name_len + lh_extra_len
      raw          = data[data_start, comp_size]
      return method.zero? ? raw : Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(raw)
    end

    pos += 46 + name_len + extra_len + comment_len
  end
  nil
end

# The real, authoritative list of tab names in the sheet (hidden tabs from
# past seasons excluded), read from the xlsx export's workbook.xml. Returns
# nil - rather than aborting - if the sheet can't be fetched or parsed, so a
# transient failure here degrades to the old per-tab-guess behavior instead
# of breaking the whole import.
def sheet_names
  url = "https://docs.google.com/spreadsheets/d/#{SHEET_ID}/export?format=xlsx"
  res = Typhoeus.get(url, followlocation: true, timeout: 30)
  return nil unless res.success?

  xml = zip_entry(res.body, 'xl/workbook.xml')
  return nil if xml.nil?

  names = []
  xml.scan(/<sheet\b([^>]*)\/>/).each do |(attrs)|
    name  = attrs[/\bname="([^"]*)"/, 1]
    state = attrs[/\bstate="([^"]*)"/, 1] || 'visible'
    next if name.nil? || state == 'hidden'

    names << CGI.unescapeHTML(name)
  end
  names
rescue StandardError => e
  warn "Could not read the sheet's tab list (#{e.message}); skipping auto-advance check."
  nil
end

def resolve_column(headers, *prefixes)
  headers.compact.find do |h|
    key = h.to_s.downcase.delete('*').strip
    prefixes.any? { |p| key.start_with?(p) }
  end
end

config  = YAML.load_file(CONFIG_FILE)
players = config['players']
abort 'No players: block in _config.yml' if players.nil? || players.empty?

# Both display name and id resolve to the id, so the sheet can use either.
lookup = {}
players.each do |p|
  lookup[p['name'].to_s.downcase.strip] = p['id']
  lookup[p['id'].to_s.downcase.strip]   = p['id']
end

content   = YAML.load_file(DATA_FILE)
weeks     = (content['weeks'] ||= [])
season    = content['season'] || Time.now.year
available = sheet_names

if options[:new_week]
  next_num = (weeks.map { |w| w['week'].to_i }.max || 0) + 1
  weeks.unshift(
    'week' => next_num,
    'total_potential' => 0,
    'worst_rationale' => '___',
    'picks' => blank_picks_for(players)
  )
  puts "Added week #{next_num}."
elsif available
  # No one has to remember to run --new-week: once the sheet grows a tab for
  # the next week, the next scheduled import notices and appends it itself.
  next_num = (weeks.map { |w| w['week'].to_i }.max || 0) + 1
  next_candidates = ["Week #{next_num} #{season}", "Week #{next_num}", "Week#{next_num}"]
  if weeks.none? { |w| w['week'].to_i == next_num } && next_candidates.any? { |c| available.include?(c) }
    weeks.unshift(
      'week' => next_num,
      'total_potential' => 0,
      'worst_rationale' => '___',
      'picks' => blank_picks_for(players)
    )
    puts "Sheet has a tab for week #{next_num} now - added it automatically."
  end
end

target = options[:week] || weeks.map { |w| w['week'].to_i }.max || 1
week   = weeks.find { |w| w['week'].to_i == target }
if week.nil?
  abort "Week #{target} is not in weeks.yml. Use --new-week to append it."
end
week['picks'] ||= {}

# Any player added to _config.yml after the week was created.
players.each do |p|
  next if week['picks'].key?(p['id'])

  week['picks'][p['id']] = { 'pick' => '___', 'status' => 'pending', 'worst' => false, 'odds' => '' }
  puts "Added missing player to week #{target}: #{p['id']}"
end

candidates = ["Week #{target} #{season}", "Week #{target}", "Week#{target}"]
# When we have the real tab list, only try names confirmed to exist - trying
# an unconfirmed name risks the gviz fallback described above fetch_tab.
try_list = available ? candidates.select { |c| available.include?(c) } : candidates
body = nil
used = nil
try_list.each do |name|
  body = fetch_tab(name)
  if body
    used = name
    break
  end
end
abort "Could not read any of these tabs from the sheet: #{candidates.inspect}" if body.nil?

puts "Reading tab #{used.inspect} for season #{season}, week #{target}."

table   = CSV.parse(body, headers: true)
headers = table.headers
friend_col = resolve_column(headers, 'friend', 'name', 'player')
bet_col    = resolve_column(headers, 'bet', 'pick')
odds_col   = resolve_column(headers, 'odds')

abort "No Friend/Bet columns found. Headers were: #{headers.inspect}" if friend_col.nil? || bet_col.nil?

updated  = []
skipped  = []
unknown  = []
seen     = []

table.each do |row|
  friend = row[friend_col].to_s.strip
  next if friend.empty?

  id = lookup[friend.downcase]
  if id.nil?
    unknown << friend
    next
  end
  seen << id

  entry = week['picks'][id]
  bet   = row[bet_col].to_s.strip
  odds  = odds_col ? normalize_odds(row[odds_col]) : ''

  next if blank_pick?(bet)

  if FINAL_STATUSES.include?(entry['status'])
    skipped << "#{id} (already #{entry['status']})"
    if entry['pick'].to_s.strip != bet
      warn "  ! #{id}: sheet says #{bet.inspect} but graded pick is #{entry['pick'].inspect} - left alone"
    end
    next
  end

  before = [entry['pick'], entry['odds']]
  entry['pick'] = bet
  entry['odds'] = odds unless odds.empty?
  updated << id if before != [entry['pick'], entry['odds']]
end

missing = players.map { |p| p['id'] } - seen
still_pending = week['picks'].select { |_, v| blank_pick?(v['pick']) }.keys

puts
puts "Updated (#{updated.size}): #{updated.join(', ')}" unless updated.empty?
puts "Already graded, left alone (#{skipped.size}): #{skipped.join(', ')}" unless skipped.empty?
puts "No pick yet (#{still_pending.size}): #{still_pending.join(', ')}" unless still_pending.empty?
puts "In config but absent from the sheet: #{missing.join(', ')}" unless missing.empty?

unless unknown.empty?
  warn
  warn "Names in the sheet with no matching player in _config.yml: #{unknown.uniq.join(', ')}"
  warn 'Add them to the players: block (or fix the spelling) and re-run.'
  exit 1
end

if options[:dry_run]
  puts
  puts 'Dry run - nothing written.'
  exit 0
end

if updated.empty?
  puts
  puts 'No changes to write.'
  exit 0
end

content['version'] = Time.now.to_i
File.write(DATA_FILE, content.to_yaml)
puts
puts "Wrote #{DATA_FILE}"
