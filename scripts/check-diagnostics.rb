#!/usr/bin/ruby
# Opt-in repeated live fixtures. Reports do not promote platform release gates.
require 'fileutils'
require 'json'
require 'open3'
require 'time'

arguments = ARGV.dup
cycles = 1
if arguments.first == '--cycles'
  arguments.shift
  value = arguments.shift
  abort 'Cycles must be an integer from 1 to 5' unless value && value.match?(/\A[1-5]\z/)
  cycles = value.to_i
end
abort 'Usage: check-diagnostics.rb [--cycles 1..5] [new-output-directory]' if arguments.length > 1 || arguments.any? { |value| value.start_with?('-') }
root = File.expand_path('..', __dir__)
output = File.expand_path(arguments.first || File.join(root, 'captures', "diagnostics-#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}"))
abort "Output already exists: #{output}" if File.exist?(output)
FileUtils.mkdir_p(output)
STDOUT.sync = true
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
revision, revision_status = Open3.capture2('/usr/bin/git', '-C', root, 'rev-parse', 'HEAD')
abort 'Cannot identify repository revision' unless revision_status.success?
steps = [
  ['recorder', 'check-ax-recorder.rb', []],
  ['poll-only', 'check-ax-recorder.rb', ['--poll-only']],
  ['native', 'check-native-tabs.rb', []],
  ['multi', 'check-native-tabs.rb', ['--multi']],
  ['partial', 'check-native-tabs.rb', ['--partial']],
  ['content', 'check-native-tabs.rb', ['--content']],
  ['unvisited', 'check-native-tabs.rb', ['--unvisited']],
  ['restart', 'check-native-tabs.rb', ['--restart']],
  ['popups', 'check-popups.rb', []]
]
results = []
write_report = lambda do
  report = { schemaVersion: 1, revision: revision.strip, cycles: cycles,
             elapsedSeconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
             completedSteps: results.length, expectedSteps: cycles * steps.length,
             result: results.length == cycles * steps.length && results.all? { |row| row[:passed] } ? 'passed' : 'incomplete or failed',
             results: results,
             scope: 'Controlled AppKit fixtures only. Enumeration/inventory gaps remain explicit; no daily-app, OS focus, display or Space-transfer release gate is closed.' }
  File.write(File.join(output, 'summary.json'), JSON.pretty_generate(report))
end
cycles.times do |cycle|
  steps.each do |name, script, flags|
    label = "#{cycle + 1}-#{name}"
    capture = File.join(output, "#{label}.json")
    puts JSON.generate(event: 'fixtureStarted', fixture: label)
    step_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = nil
    File.open(File.join(output, "#{label}.log"), 'w') do |log|
      Open3.popen2e('/usr/bin/ruby', File.join(root, 'scripts', script), *flags, capture) do |input, stream, process|
        input.close
        IO.copy_stream(stream, log)
        status = process.value
      end
    end
    row = { fixture: label, processSucceeded: status.success?,
            elapsedSeconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_start }
    begin
      report = JSON.parse(File.read(capture))
      informational = name == 'restart' ? %w[enumeratedRepresentatives physicalInventoryComplete] : %w[enumeratedRepresentatives]
      checks = report.fetch('checks', {})
      required = checks.reject { |key, _| informational.include?(key) }
      row[:requiredChecks] = required
      row[:informationalChecks] = checks.select { |key, _| informational.include?(key) }
      row[:observation] = report['observation'] || report['scope']
      lifecycle = %w[recorder poll-only].include?(name)
      row[:passed] = status.success? && (lifecycle ? report['result'] == 'passed' : !required.empty? && required.values.all? { |value| value == true })
      row[:passed] &&= report['workspaceEventsEnabled'] == false if name == 'poll-only'
    rescue JSON::ParserError, Errno::ENOENT, KeyError => error
      row[:passed] = false
      row[:error] = error.message
    end
    results << row
    write_report.call
    puts JSON.generate(event: 'fixtureCompleted', fixture: label, passed: row[:passed], informationalChecks: row[:informationalChecks])
  end
end
puts JSON.generate(event: 'diagnosticsCompleted', report: File.join(output, 'summary.json'), passed: results.all? { |row| row[:passed] })
exit(results.all? { |row| row[:passed] } ? 0 : 1)
