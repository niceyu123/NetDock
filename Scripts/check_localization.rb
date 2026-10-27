#!/usr/bin/env ruby
require 'json'
Dir.chdir(File.expand_path('..', __dir__))
catalog = JSON.parse(File.read('Shared/Resources/Localizable.xcstrings'))
strings = catalog.fetch('strings')
errors = []
strings.each do |key, entry|
  %w[zh-Hans en].each do |language|
    text = entry.dig('localizations', language, 'stringUnit', 'value')
    errors << "Missing #{language}: #{key}" if text.nil? || text.empty?
  end
end
Dir['Shared/**/*.swift', 'Apps/**/*.swift'].each do |file|
  File.read(file).scan(/(?:\.t|L10n\.text)\("([^"\\]+)"/).flatten.each do |key|
    errors << "Unknown localization key #{key}: #{file}" unless strings.key?(key)
  end
end
source = File.read('Packages/NetDockCore/Sources/NetDockCore/Models/ConnectionState.swift')
code_block = source.split('public enum Code:')[1].split('public let code:')[0]
code_block.scan(/case ([^\n]+)/).flatten.each do |line|
  line.split(',').map(&:strip).each { |code| errors << "Missing error.#{code}" unless strings.key?("error.#{code}") }
end
abort errors.join("\n") unless errors.empty?
puts "Localization OK: #{strings.count} keys, zh-Hans + en, all error codes covered."
