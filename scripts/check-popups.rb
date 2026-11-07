#!/usr/bin/ruby
# Controlled panel/sheet metadata and recorder continuity, not OS focus parity.
require 'fileutils'
require 'json'
require 'open3'
require 'timeout'
require 'tmpdir'

root = File.expand_path('..', __dir__)
abort 'Usage: check-popups.rb [new-output.json]' if ARGV.length > 1
output = ARGV.first || File.join(root, 'captures', 'popup-fixture.json')
abort "Output already exists: #{output}" if File.exist?(output)
wrapper = File.join(root, 'scripts', 'swift.sh')
abort 'Build failed' unless system(wrapper, 'build')
bin, status = Open3.capture2(wrapper, 'build', '--show-bin-path')
abort 'Cannot resolve build directory' unless status.success?
bundle_id = 'dev.paperi.PopupFixture'
records = []
stages = []
Dir.mktmpdir('paperi-popups-', File.join(root, '.build')) do |temporary|
  app = File.join(temporary, 'PaperiPopupFixture.app')
  macos = File.join(app, 'Contents', 'MacOS')
  FileUtils.mkdir_p(macos)
  FileUtils.cp(File.join(bin.strip, 'PaperiAXFixture'), File.join(macos, 'PaperiAXFixture'))
  File.write(File.join(app, 'Contents', 'Info.plist'), <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>#{bundle_id}</string>
      <key>CFBundleExecutable</key><string>PaperiAXFixture</string>
      <key>CFBundleName</key><string>PaperiPopupFixture</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleVersion</key><string>1</string>
    </dict></plist>
  PLIST
  log = File.join(temporary, 'fixture.jsonl')
  input, stream, recorder = Open3.popen2(File.join(bin.strip, 'paperi'), 'record', '17',
                                       '--bundle-id', bundle_id, '--window-evidence')
  input.close
  queue = Queue.new
  reader = Thread.new do
    begin
      stream.each_line { |line| queue << JSON.parse(line) }
    rescue StandardError => error
      queue << error
    ensure
      queue << nil
    end
  end
  next_record = lambda do
    row = queue.pop
    abort 'Recorder ended before fixture completed' unless row
    raise row if row.is_a?(Exception)
    records << row
    row
  end
  launcher = nil
  consumed = 0
  begin
    Timeout.timeout(30) do
      loop { break if next_record.call['event'] == 'recorderReady' }
      launcher = Process.spawn('/usr/bin/open', '-g', '-n', '-W', app, '--args', log, '--popups')
      loop do
        rows = File.exist?(log) ? File.readlines(log).map { |line| JSON.parse(line) } : []
        rows.drop(consumed).each do |row|
          next unless row['event'].start_with?('action-')
          evidence = loop do
            sample = next_record.call
            break sample if sample['event'] == 'windowEvidence' && sample['captureStartedUptime'] >= row['uptime'] + 0.15
          end
          abort 'Accessibility trust is required' unless evidence['accessibilityTrusted']
          abort 'Wrong or missing fixture process' unless evidence['applications'].length == 1 && evidence['applications'][0]['pid'] == row['pid']
          current = JSON.parse(File.readlines(log).last)['event'] == row['event']
          stages << { fixture: row, evidence: evidence, stageStillCurrent: current }
        end
        consumed = rows.length
        break if rows.any? { |row| row['event'] == 'terminating' }
        sleep 0.05
      end
      loop { break if next_record.call['event'] == 'recordingEnded' }
      abort 'Recorder failed' unless recorder.value.success?
    end
  ensure
    Process.kill('TERM', recorder.pid) if recorder.alive?
    recorder.value
    reader.join
    stream.close
    Process.wait(launcher) if launcher
  end
end
abort 'Fixture stages were incomplete' unless stages.map { |stage| stage[:fixture]['event'] } == [1, 3, 5, 7, 9, 11].map { |n| "action-#{n}.0" }
at = lambda { |n| stages.find { |stage| stage[:fixture]['event'] == "action-#{n}.0" } }
app_at = lambda { |n| at.call(n)[:evidence]['applications'][0] }
document_id = at.call(1)[:fixture]['documentID']
panel_id = at.call(3)[:fixture]['panelID']
sheet_id = at.call(7)[:fixture]['sheetID']
checks = {}
checks[:fixtureGroundTruth] = [document_id, panel_id, sheet_id].all? { |id| id > 0 } &&
  [document_id, panel_id, sheet_id].uniq.length == 3 && at.call(3)[:fixture]['panelVisible'] &&
  !at.call(5)[:fixture]['panelVisible'] && at.call(7)[:fixture]['sheetVisible'] &&
  at.call(7)[:fixture]['attachedSheetID'] == sheet_id && !at.call(9)[:fixture]['sheetVisible'] &&
  !at.call(11)[:fixture]['documentVisible']
checks[:stageCoverage] = stages.all? { |stage| stage[:stageStillCurrent] && !stage[:evidence]['applications'][0]['truncated'] }
checks[:documentRemainsEligible] = [1, 3, 5, 7, 9].all? do |n|
  app_at.call(n)['windows'].any? { |row| row['windowID'] == document_id && row['eligibility'] == 'tiled' }
end
checks[:panelExcluded] = app_at.call(3)['windows'].any? { |row| row['windowID'] == panel_id && row['eligibility'] == 'excluded' }
checks[:sheetExcluded] = app_at.call(7)['windows'].any? { |row| row['windowID'] == sheet_id && row['eligibility'] == 'excluded' }
checks[:sheetFocusDistinguishedFromDocumentOwner] = app_at.call(7)['focusedWindowID'] == sheet_id &&
  app_at.call(7).dig('focusedUI', 'role') == 'AXSheet' && app_at.call(7).dig('focusedUI', 'windowID') == document_id
checks[:documentFocusReturnsAfterSheet] = app_at.call(9)['focusedWindowID'] == document_id &&
  app_at.call(9).dig('focusedUI', 'role') == 'AXWindow'
checks[:documentObservableAfterDismissal] = [5, 9].all? do |n|
  app_at.call(n)['windows'].any? { |row| row['windowID'] == document_id && row['observed'] && row['eligibility'] == 'tiled' }
end
checks[:eventsContinueAfterDismissal] = [5, 9].all? do |n|
  records.any? do |row|
    row['event'] == 'AXMoved' && row['windowID'] == document_id &&
      row['uptime'] >= at.call(n)[:fixture]['uptime'] - 0.2 && row['uptime'] <= at.call(n)[:evidence]['uptime']
  end
end
checks[:closedDocumentCleared] = app_at.call(11)['windows'].none? { |row| row['windowID'] == document_id }
checks[:emptyCaptureStaysUnconfirmed] = app_at.call(11).dig('windowCoverage', 'status') == 'noReferences' &&
  app_at.call(11).dig('windowCoverage', 'confirmsEmptyWindowSet') == false
checks[:nativeSourcesRemoved] = records.find { |row| row['event'] == 'recordingEnded' }.dig('teardown', 'sourcesStillInstalled') == 0
forbidden = %w[title label description AXTitle AXDescription AXValue axFrame]
private_values = lambda do |value|
  case value
  when Hash then (value.keys & forbidden).empty? && value.values.all? { |item| private_values.call(item) }
  when Array then value.all? { |item| private_values.call(item) }
  else true
  end
end
checks[:noContentValues] = stages.all? { |stage| private_values.call(stage[:evidence]) }
panel_focus_returned = app_at.call(5)['focusedWindowID'] == document_id
FileUtils.mkdir_p(File.dirname(output))
report = { schemaVersion: 1, result: checks.values.all? ? 'passed' : 'inconclusive', checks: checks,
           documentFocusReturnedAfterPanel: panel_focus_returned, events: records.group_by { |row| row['event'] }.transform_values(&:length),
           stages: stages, scope: 'Controlled background panel/sheet policy and notification continuity only; no live management or cross-app focus recovery.' }
File.write(output, JSON.pretty_generate(report))
puts JSON.pretty_generate(report.reject { |key, _| key == :stages }.merge(output: output))
