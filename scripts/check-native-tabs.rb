#!/usr/bin/ruby
# Opt-in structural investigation, not an assertion of native-tab support.
require 'fileutils'
require 'json'
require 'open3'
require 'timeout'
require 'tmpdir'

root = File.expand_path('..', __dir__)
wrapper = File.join(root, 'scripts', 'swift.sh')
abort 'Build failed' unless system(wrapper, 'build')
bin, status = Open3.capture2(wrapper, 'build', '--show-bin-path')
abort 'Cannot resolve build directory' unless status.success?
bin = bin.strip
bundle_id = 'dev.paperi.NativeTabFixture'
output = ARGV.first || File.join(root, 'captures', 'native-tab-fixture.json')
abort "Output already exists: #{output}" if File.exist?(output)
stages = []

Dir.mktmpdir('paperi-tabs-', File.join(root, '.build')) do |temporary|
  app = File.join(temporary, 'PaperiNativeTabFixture.app')
  macos = File.join(app, 'Contents', 'MacOS')
  FileUtils.mkdir_p(macos)
  FileUtils.cp(File.join(bin, 'PaperiAXFixture'), File.join(macos, 'PaperiAXFixture'))
  File.write(File.join(app, 'Contents', 'Info.plist'), <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>#{bundle_id}</string>
      <key>CFBundleExecutable</key><string>PaperiAXFixture</string>
      <key>CFBundleName</key><string>PaperiNativeTabFixture</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleVersion</key><string>1</string>
    </dict></plist>
  PLIST
  log = File.join(temporary, 'fixture.jsonl')
  launcher = Process.spawn('/usr/bin/open', '-g', '-n', '-W', app, '--args', log, '--tabs')
  consumed = 0
  begin
    Timeout.timeout(35) do
      loop do
        rows = File.exist?(log) ? File.readlines(log).map { |line| JSON.parse(line) } : []
        rows.drop(consumed).each do |row|
          if row.fetch('event').start_with?('action-')
            # Allow AppKit to publish its asynchronous accessibility changes.
            sleep 0.15
            raw, result = Open3.capture2(File.join(bin, 'paperi'), 'tab-evidence', bundle_id)
            abort 'Tab evidence command failed' unless result.success?
            evidence = JSON.parse(raw)
            abort 'Accessibility trust is required' unless evidence.fetch('accessibilityTrusted')
            abort 'Fixture application not discovered' if evidence.fetch('applications').empty?
            abort 'Wrong fixture process observed' unless evidence.fetch('applications').all? { |app_row| app_row['pid'] == row['pid'] }
            current = JSON.parse(File.readlines(log).last).fetch('event') == row.fetch('event')
            stages << { fixture: row, evidence: evidence, stageStillCurrent: current }
          end
        end
        consumed = rows.length
        break if rows.any? { |row| row['event'] == 'terminating' }
        sleep 0.05
      end
    end
  ensure
    Process.wait(launcher)
  end
end
abort 'Fixture did not complete all eight tab stages' unless stages.length == 8
truth = stages.map { |stage| [stage[:fixture]['event'], stage[:fixture]['tabWindows']] }.to_h
abort 'Fixture stages were incomplete or duplicated' unless truth.keys == [1, 3, 5, 7, 9, 11, 13, 15].map { |n| "action-#{n}.0" }
ids = truth.fetch('action-1.0').map { |window| window.fetch('id') }.sort
abort 'Fixture window IDs were invalid' unless ids.length == 2 && ids.uniq.length == 2 && ids.all? { |id| id > 0 }
[3, 5, 7, 11].each do |n|
  abort "Native merge was not confirmed at stage #{n}" unless truth.fetch("action-#{n}.0").all? { |window| window['members'].sort == ids }
end
abort 'Native selection was not confirmed' unless truth.fetch('action-5.0').first['selected'] == truth.fetch('action-1.0').last['id'] &&
                                                     truth.fetch('action-7.0').first['selected'] == truth.fetch('action-1.0').first['id']
abort 'Native detach was not confirmed' unless truth.fetch('action-9.0').all? { |window| window['members'].empty? }
abort 'Native close was not confirmed' unless truth.fetch('action-13.0').count { |window| window['visible'] } == 1 &&
                                                truth.fetch('action-15.0').none? { |window| window['visible'] }
FileUtils.mkdir_p(File.dirname(output))
complete = stages.all? do |stage|
  apps = stage[:evidence]['applications']
  visible = stage[:fixture]['tabWindows'].any? { |window| window['visible'] }
  stage[:stageStillCurrent] && apps.all? do |app|
    app['windowsError'] == 0 && !app['truncated'] && (!visible || !app['roots'].empty?)
  end
end
observation = complete ? 'evidence-collected; grouping requires review' : 'inconclusive AX coverage'
File.write(output, JSON.pretty_generate(schemaVersion: 1, observation: observation, stages: stages,
  scope: 'Controlled fixture evidence only. Native-tab grouping is not inferred from equal frames or titles.'))
summary = stages.map do |stage|
  apps = stage[:evidence]['applications']
  nodes = apps.flat_map { |app| app['nodes'] }
  { stage: stage[:fixture]['event'], truth: stage[:fixture]['tabWindows'],
    axWindowIDs: nodes.select { |node| node.key?('enumeratedWindowIndex') }.map { |node| node['windowID'] },
    windowsErrors: apps.map { |app| app['windowsError'] },
    tabControls: nodes.select { |node| ['AXTabGroup', 'AXRadioButton'].include?(node['AXRole']) }.map do |node|
      node.select { |key, _| ['node', 'AXRole', 'AXValue', 'AXSelected', 'AXChildren', 'AXSelectedChildren', 'AXWindow'].include?(key) }
    end,
    truncated: apps.any? { |app| app['truncated'] } }
end
puts JSON.pretty_generate(output: output, observation: observation, stages: summary)
