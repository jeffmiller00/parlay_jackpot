#!/usr/bin/env ruby
# frozen_string_literal: true
# Temporary diagnostic script - not part of the app. Reproduces the exact
# request grade_picks.rb sends and prints full, untruncated diagnostics.

require 'json'
require 'typhoeus'
require 'dotenv/load'

api_key = ENV['OPENAI_KEY'] || ENV['OPENAI_API_KEY']
abort 'No OPENAI_KEY set.' if api_key.nil? || api_key.strip.empty?

puts "api_key.length: #{api_key.length}"
puts "api_key.bytesize: #{api_key.bytesize}"
puts "api_key == api_key.strip: #{api_key == api_key.strip}"
puts "api_key has leading/trailing whitespace: #{api_key != api_key.strip}"
puts "api_key contains \\n: #{api_key.include?("\n")}"
puts "api_key contains \\r: #{api_key.include?("\r")}"
puts "api_key encoding: #{api_key.encoding}"
puts "api_key valid encoding?: #{api_key.valid_encoding?}"

prompt = 'This bet was placed for week 1 of the 2026 football season. The games ran ' \
         '2026-09-10 through 2026-09-15. It may be an NFL game or a college football ' \
         'game - do not assume NFL. College football week numbers do not match NFL ' \
         'week numbers, so identify the game by date, not by week number. NFL box ' \
         'scores: https://www.espn.com/nfl/scoreboard/_/week/1/year/2026/seasontype/2 . ' \
         'College box scores: https://www.espn.com/college-football/scoreboard/_/date/20260912 . ' \
         'Did this bet win? Dallas Cowboys -3 If you do not know, or it has not been ' \
         'settled yet, respond with a result of "unknown". Respond only with JSON ' \
         '{"result": true/false/unknown, "rationale": "..."}'

body = JSON.dump(
  model: 'gpt-5',
  reasoning: { effort: 'low' },
  tools: [{ type: 'web_search' }],
  input: prompt
)

puts "Ruby version: #{RUBY_VERSION}"
puts "Typhoeus version: #{Typhoeus::VERSION}"
puts "Ethon version: #{Ethon::VERSION}" if defined?(Ethon::VERSION)
puts "Body bytesize: #{body.bytesize}"
puts "Body encoding: #{body.encoding}"
puts "Body valid encoding?: #{body.valid_encoding?}"
puts '---BODY---'
puts body
puts '---END BODY---'

request = Typhoeus::Request.new(
  'https://api.openai.com/v1/responses',
  method: :post,
  headers: {
    'Content-Type' => 'application/json',
    'Authorization' => "Bearer #{api_key}"
  },
  body: body,
  timeout: 120
)

response = request.run

puts
puts "HTTP CODE: #{response.code}"
puts "RETURN CODE: #{response.return_code}"
puts "TIMED OUT: #{response.timed_out?}"
puts '---RESPONSE HEADERS---'
puts response.headers
puts '---RESPONSE BODY (full)---'
puts response.body
puts '---END RESPONSE BODY---'
puts
puts "PRIMARY IP: #{response.primary_ip}" if response.respond_to?(:primary_ip)
puts '---REQUEST HEADERS AS SENT (redacted)---'
request.options[:headers].each do |k, v|
  v = 'Bearer [REDACTED]' if k.to_s.downcase == 'authorization'
  puts "#{k}: #{v}"
end
