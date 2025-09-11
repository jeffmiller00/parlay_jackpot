#!/usr/bin/env ruby
#
# Utility script to edit _data/weeks.yml
# Usage examples:
#   ruby scripts/weeks_editor.rb add_week 3
#   ruby scripts/weeks_editor.rb set_pick 2 andy "Some pick text" won -130
#   ruby scripts/weeks_editor.rb mark_worst 1 jeff true
#   ruby scripts/weeks_editor.rb recalc_total 1
#
# Notes:
# - The "total_potential" recalculation logic is domain-specific; placeholder provided.
# - Script preserves formatting where practical by rewriting YAML.

# - week: _x_
#   total_potential: 0
#   picks:
#     andy: { pick: _, status: pending, worst: false, odds: "" }
#     adam: { pick: _, status: pending, worst: false, odds: "" }
#     sam:  { pick: _, status: pending, worst: false, odds: "" }
#     jeff: { pick: _, status: pending, worst: false, odds: "" }
#     mr_gaddi: { pick: _, status: pending, worst: false, odds: "" }
#     brad: { pick: _, status: pending, worst: false, odds: "" }
#     joe: { pick: _, status: pending, worst: false, odds: "" }
#     jma: { pick: _, status: pending, worst: false, odds: "" }
#     mike: { pick: _, status: pending, worst: false, odds: "" }
#     daniel: { pick: _, status: pending, worst: false, odds: "" }

require 'yaml'
require 'fileutils'
require 'typhoeus'
require 'json'
require 'dotenv/load'
require 'pry'

# Status sets (introducing AI-evaluated variants that behave identically)
WIN_STATUSES  = %w[won ai_won].freeze
LOSS_STATUSES = %w[lost ai_lost].freeze
FINAL_STATUSES = (WIN_STATUSES + LOSS_STATUSES).freeze


DATA_FILE = File.expand_path('../_data/weeks.yml', __dir__)

unless File.exist?(DATA_FILE)
  warn "Data file not found: #{DATA_FILE}"
  exit 1
end

@content = YAML.load_file(DATA_FILE)
@weeks = @content['weeks'] || []
@current_week_num = @weeks.map { |w| w['week'] }.max || 1

def ai_guess?
  !!(ENV['JEKYLL_ENV'] == 'production' || true)
end

# Find week hash by number
def current_week()
  @weeks.find { |w| w['week'].to_i == @current_week_num.to_i }
end


puts '|==================================================='
puts '|=== SCRIPT START =================================='
puts '|==================================================='

boxscore_url = "https://www.espn.com/nfl/scoreboard/_/week/#{@current_week_num}/year/2025/seasontype/2"
prompt = ''
api_key = ENV['OPENAI_KEY'] || ENV['OPENAI_API_KEY']

allowed_days = %w[Thursday Sunday Monday]
if !allowed_days.include?(Date.today.strftime('%A'))
  puts "| Today is #{Date.today.strftime('%A')} - skipping bet evaluation."
elsif Date.today.strftime('%A') == 'Thursday' && Time.now.hour < 19
  puts "| Today is #{Date.today.strftime('%A')} before 7 PM - skipping bet evaluation."
elsif !ai_guess?
  puts '| I do not feel like guessing right now.'
else
  current_week.dig('picks').each do |name, pick_info|
    if pick_info['pick'] == '_'
      puts "| #{name} has not made a pick yet, skipping"
      next
    end
    status = pick_info['status']
    if FINAL_STATUSES.include?(status)
      puts "| #{name} already marked as #{status}, skipping"
      next
    end

    puts "| #{name}: #{pick_info['pick']} (#{status})"
    prompt = "Based on any of these box scores for Week ##{@current_week_num} of the NFL season: #{boxscore_url} Did this bet win? #{pick_info['pick']} If you don't know or it has not been settled yet, please respond with a result of \"pending\". Please respond only with JSON {result: true/false/unknown, rationale: \"...\" }"

    if api_key.nil? || api_key.strip.empty?
      puts '| Skipping OpenAI call (no OPENAI_KEY / OPENAI_API_KEY set)'
    else
      puts '| Calling OpenAI responses endpoint via Typhoeus'
      request_body = {
        model: 'gpt-5', # keep requested model name; change if unavailable
        reasoning: { effort: "low" },
        tools: [{"type": "web_search"}],
        input: prompt
      }
      response = Typhoeus.post(
        'https://api.openai.com/v1/responses',
        headers: {
          'Content-Type' => 'application/json',
          'Authorization' => "Bearer #{api_key}"
        },
        body: JSON.dump(request_body),
        timeout: 30
      )
      if response.timed_out?
        puts '| OpenAI request timed out'
      elsif !response.success?
        puts "| OpenAI request failed (status #{response.code}): #{response.body[0,200]}"
      else
        begin
          data = JSON.parse(response.body)
          # Attempt to pull a plausible text field; fallback to raw snippet
          text = data.dig('output').map{|o| o['content']}.compact.flatten.dig(0,'text') rescue nil
          verdict = JSON.parse(text) if text

          if verdict['result'] == true
            pick_info['status'] = 'ai_won'
            puts "| Marking #{name} as ai_won. Rationale: #{verdict['rationale']}"
          elsif verdict['result'] == false
            pick_info['status'] = 'ai_lost'
            puts "| Marking #{name} as ai_lost. Rationale: #{verdict['rationale']}"
          else
            puts "| Leaving #{name} as #{status} (verdict: #{verdict['result']}). Rationale: #{verdict['rationale']}"
          end
        rescue => e
          puts "| Failed to parse OpenAI JSON: #{e}"
        end
      end
    end
  end
end

puts '|==================================================='
puts '|=== SCRIPT END ===================================='
puts '|==================================================='

@content['version'] = Time.now.to_i

# Persist file
File.write(DATA_FILE, @content.to_yaml)
puts 'Saved _data/weeks.yml'
