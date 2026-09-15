#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Grade a week's pending picks with the OpenAI responses API and record the
# verdicts in _data/weeks.yml.
#
#   bundle exec ruby scripts/grade_picks.rb              # latest week in weeks.yml
#   bundle exec ruby scripts/grade_picks.rb --week 3
#   bundle exec ruby scripts/grade_picks.rb --dry-run    # call the API, write nothing
#
# This used to run from a Jekyll after_init hook, which meant it fired on every
# build - including the Cloudflare Pages build, where the rewritten data file
# was thrown away when the container exited. It is a Monday chore, so it is a
# script you run on Monday.
#
# Verdicts are written as ai_won / ai_lost so they stay distinguishable from
# results entered by hand. Picks already graded are never re-graded.

require 'yaml'
require 'json'
require 'date'
require 'optparse'
require 'typhoeus'
require 'dotenv/load'

ROOT      = File.expand_path('..', __dir__)
DATA_FILE = File.join(ROOT, '_data', 'weeks.yml')

WIN_STATUSES   = %w[won ai_won].freeze
LOSS_STATUSES  = %w[lost ai_lost].freeze
FINAL_STATUSES = (WIN_STATUSES + LOSS_STATUSES).freeze

MODEL = ENV.fetch('PARLAY_MODEL', 'gpt-5')

options = { dry_run: false, week: nil }
OptionParser.new do |o|
  o.banner = 'Usage: grade_picks.rb [options]'
  o.on('--week N', Integer, 'Week to grade (default: latest in weeks.yml)') { |v| options[:week] = v }
  o.on('--dry-run', 'Call the API but do not write results') { options[:dry_run] = true }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!

# A pick is "not made yet" if it is empty or a placeholder.
def blank_pick?(value)
  s = value.to_s.strip
  s.empty? || s.match?(/\A_+\z/) || s.match?(/\A-+\z/) || s.casecmp?('none')
end

def week_date_range(season, week)
  url = 'https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard' \
        "?dates=#{season}&seasontype=2&week=#{week}"
  res = Typhoeus.get(url, followlocation: true, timeout: 30)
  return nil unless res.success?

  dates = JSON.parse(res.body).fetch('events', [])
              .map { |e| e['date'].to_s[0, 10] }
              .reject(&:empty?)
              .sort
  dates.empty? ? nil : [dates.first, dates.last]
rescue StandardError
  nil
end

def extract_text(payload)
  Array(payload['output'])
    .map { |o| o['content'] }
    .compact
    .flatten
    .map { |c| c['text'] }
    .compact
    .first
end

def parse_verdict(text)
  cleaned = text.to_s.strip.sub(/\A```(?:json)?/, '').sub(/```\z/, '').strip
  JSON.parse(cleaned)
rescue JSON::ParserError
  nil
end

api_key = (ENV['OPENAI_KEY'] || ENV['OPENAI_API_KEY']).to_s.strip
abort 'No OPENAI_KEY / OPENAI_API_KEY set.' if api_key.empty?
# A stray trailing newline in the secret (easy to introduce when setting it)
# breaks the HTTP header/body framing when libcurl writes the raw
# "Authorization: Bearer ...\n" header, corrupting the request in a way
# that shows up as OpenAI rejecting the body as invalid JSON.

content = YAML.load_file(DATA_FILE)
weeks   = content['weeks'] || []
season  = content['season'] || Time.now.year
abort 'No weeks in weeks.yml.' if weeks.empty?

target = options[:week] || weeks.map { |w| w['week'].to_i }.max
week   = weeks.find { |w| w['week'].to_i == target }
abort "Week #{target} is not in weeks.yml." if week.nil?

# Picks are not always NFL - the pool takes college games too. College week
# numbers do not line up with NFL ones (NFL week 1 of 2026 runs Sep 10-15,
# which straddles what ESPN calls college week 2), so the college scoreboard
# is addressed by date and the model is told to match on dates.
nfl_url = "https://www.espn.com/nfl/scoreboard/_/week/#{target}/year/#{season}/seasontype/2"
range   = week_date_range(season, target)

if range
  window   = "The games ran #{range.first} through #{range.last}. "
  cfb_urls = (Date.parse(range.first)..Date.parse(range.last)).select(&:saturday?).map do |d|
    "https://www.espn.com/college-football/scoreboard/_/date/#{d.strftime('%Y%m%d')}"
  end
else
  window   = ''
  cfb_urls = ["https://www.espn.com/college-football/scoreboard/_/year/#{season}"]
end

puts "Grading season #{season}, week #{target}."
puts "Window:  #{range ? "#{range.first} to #{range.last}" : 'unknown'}"
puts "NFL:     #{nfl_url}"
puts "College: #{cfb_urls.join(' ')}"
puts

graded    = []
unchanged = []

week['picks'].each do |name, info|
  if blank_pick?(info['pick'])
    unchanged << "#{name} (no pick)"
    next
  end
  if FINAL_STATUSES.include?(info['status'])
    unchanged << "#{name} (already #{info['status']})"
    next
  end

  prompt = "This bet was placed for week #{target} of the #{season} football season. #{window}" \
           'It may be an NFL game or a college football game - do not assume NFL. College ' \
           'football week numbers do not match NFL week numbers, so identify the game by ' \
           "date, not by week number. NFL box scores: #{nfl_url} . College box scores: " \
           "#{cfb_urls.join(' ')} . Did this bet win? #{info['pick']} " \
           'If you do not know, or it has not been settled yet, respond with a result of ' \
           '"unknown". Respond only with JSON {"result": true/false/unknown, "rationale": "..."}'

  response = Typhoeus.post(
    'https://api.openai.com/v1/responses',
    headers: {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{api_key}"
    },
    body: JSON.dump(
      model: MODEL,
      reasoning: { effort: 'low' },
      tools: [{ type: 'web_search' }],
      input: prompt
    ),
    timeout: 120
  )

  if response.timed_out?
    warn "  #{name}: request timed out"
    next
  end
  unless response.success?
    warn "  #{name}: request failed (#{response.code}) #{response.body.to_s[0, 200]}"
    next
  end

  verdict = parse_verdict(extract_text(JSON.parse(response.body)))
  if verdict.nil?
    warn "  #{name}: could not parse a verdict"
    next
  end

  case verdict['result']
  when true
    info['status'] = 'ai_won'
    graded << name
    puts "  #{name}: WON  - #{info['pick']}"
  when false
    info['status'] = 'ai_lost'
    graded << name
    puts "  #{name}: LOST - #{info['pick']}"
  else
    unchanged << "#{name} (unsettled)"
    puts "  #{name}: unsettled - #{verdict['rationale']}"
  end
end

puts
puts "Graded (#{graded.size}): #{graded.join(', ')}" unless graded.empty?
puts "Left alone (#{unchanged.size}): #{unchanged.join(', ')}" unless unchanged.empty?

if options[:dry_run]
  puts
  puts 'Dry run - nothing written.'
  exit 0
end

if graded.empty?
  puts
  puts 'No changes to write.'
  exit 0
end

content['version'] = Time.now.to_i
File.write(DATA_FILE, content.to_yaml)
puts
puts "Wrote #{DATA_FILE}"
