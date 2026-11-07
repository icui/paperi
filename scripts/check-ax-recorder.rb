#!/usr/bin/ruby
# Opt-in live check. Requires Accessibility trust for the built paperi binary.
require 'fileutils'
require 'json'
require 'open3'
require 'timeout'
require 'tmpdir'

root = File.expand_path('..', __dir__)
arguments = ARGV.dup
accessory = arguments.delete('--accessory') != nil
abort 'Usage: check-ax-recorder.rb [--accessory] [new-output.json]' if arguments.length > 1 || arguments.any? { |argument| argument.start_with?('-') }
output = arguments.first
abort "Output already exists: #{output}" if output && File.exist?(output)
wrapper = File.join(root, 'scripts', 'swift.sh')
abort 'Build failed' unless system(wrapper, 'build')
bin, status = Open3.capture2(wrapper, 'build', '--show-bin-path')
abort 'Cannot resolve build directory' unless status.success?
bin = bin.strip
bundle_id = accessory ? 'dev.paperi.AccessoryAXFixture' : 'dev.paperi.AXFixture'
required = %w[NSWorkspaceDidLaunchApplicationNotification AXWindowCreated AXMoved AXResized
              AXWindowMiniaturized AXWindowDeminiaturized AXUIElementDestroyed
              NSWorkspaceDidTerminateApplicationNotification]
required -= %w[NSWorkspaceDidLaunchApplicationNotification NSWorkspaceDidTerminateApplicationNotification] if accessory

Dir.mktmpdir('paperi-ax-', File.join(root, '.build')) do |temporary|
  app = File.join(temporary, 'PaperiAXFixture.app')
  macos = File.join(app, 'Contents', 'MacOS')
  FileUtils.mkdir_p(macos)
  FileUtils.cp(File.join(bin, 'PaperiAXFixture'), File.join(macos, 'PaperiAXFixture'))
  File.write(File.join(app, 'Contents', 'Info.plist'), <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>#{bundle_id}</string>
      <key>CFBundleExecutable</key><string>PaperiAXFixture</string>
      <key>CFBundleName</key><string>PaperiAXFixture</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleVersion</key><string>1</string>
    </dict></plist>
  PLIST

  counts = Hash.new(0)
  windows = Hash.new { |hash, key| hash[key] = [] }
  discovered = []
  recorded_pids = []
  teardown = nil
  fixture_pid = nil
  launcher = nil
  recorder_pid = nil
  fixture_log = File.join(temporary, 'fixture.jsonl')
  launcher_log = File.join(temporary, 'launcher.log')
  begin
    Timeout.timeout(40) do
      recorder_args = [File.join(bin, 'paperi'), 'record', accessory ? '19' : '16', '--bundle-id', bundle_id]
      recorder_args += ['--reconcile-every', '1'] if accessory
      IO.popen(recorder_args, 'r') do |stream|
        recorder_pid = stream.pid
        stream.each_line do |line|
          begin
            row = JSON.parse(line)
          rescue JSON::ParserError
            abort "Recorder did not emit JSONL: #{line.strip}"
          end
          event = row.fetch('event')
          counts[event] += 1
          teardown = row['teardown'] if event == 'recordingEnded'
          if event == 'recorderReady'
            abort 'Fixture already running or duplicate readiness' unless counts[event] == 1 && row['observerCount'] == 0
            fixture_args = [fixture_log] + (accessory ? ['--accessory'] : [])
            launcher = Process.spawn('/usr/bin/open', '-g', '-n', '-W', app, '--args', *fixture_args,
                                     out: launcher_log, err: launcher_log)
          end
          if event == 'NSWorkspaceDidLaunchApplicationNotification'
            fixture_pid = row.fetch('pid')
          end
          if row['pid'] && fixture_pid && row['pid'] != fixture_pid
            abort 'Unexpected process in filtered recording'
          end
          windows[event] << row['windowID'] if row.key?('windowID')
          recorded_pids << row['pid'] if row['pid']
          discovered.concat(row.fetch('windows', []).map { |window| window['windowID'] }) if event == 'windowDiscovery'
        end
      end
      recorder_pid = nil
      abort 'Recorder exited unsuccessfully' unless $?.success?
    end
    Process.wait(launcher) if launcher
    launcher = nil
    abort "Fixture launch failed: #{File.read(launcher_log)}" unless $?.success?
    abort 'Fixture did not reach applicationDidFinishLaunching' unless File.exist?(fixture_log)
    fixture_rows = File.readlines(fixture_log).map { |line| JSON.parse(line) }
    abort 'Recorded launch PID does not match the fixture' if fixture_pid && fixture_pid != fixture_rows.first.fetch('pid')
    abort 'Unexpected process in filtered recording' unless recorded_pids.all? { |pid| pid == fixture_rows.first.fetch('pid') }
    fixture_actions = fixture_rows.map { |row| row.fetch('event') }
    abort "Fixture did not complete: #{fixture_actions}" unless fixture_actions.include?('terminating')
    missing = required.reject { |event| counts[event] > 0 }
    abort "Missing live events: #{missing.join(', ')}; fixture: #{fixture_rows.first}; actions: #{fixture_actions}; counts: #{JSON.generate(counts)}" unless missing.empty?
    created = windows['AXWindowCreated'].select { |id| id && id > 0 }
    destroyed = windows['AXUIElementDestroyed']
    abort 'Created/destroyed window identity was not retained' if created.empty? || (created & destroyed).empty?
    abort 'Fixture window events were missing or duplicated' unless created.length == 1 && destroyed == created
    abort 'Recording did not end cleanly' unless counts['recordingEnded'] == 1
    abort 'Native/workspace sources remain after recording' unless teardown &&
      teardown['sourcesStillInstalled'] == 0 && teardown['workspaceObserverCount'] == 0
    abort 'Periodic reconciliation did not discover the accessory window' if accessory &&
      (counts['recorderReconciled'] == 0 || (discovered & destroyed).empty?)
    report = { result: 'passed', fixtureMode: accessory ? 'accessory with periodic reconciliation' : 'regular',
               fixtureBundleID: bundle_id, events: counts, teardown: teardown,
               scope: 'Disposable AppKit fixture only; no native-tab, popup, display or Space-transfer gate verified' }
    if output
      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, JSON.pretty_generate(report))
    end
    puts JSON.pretty_generate(report)
  ensure
    if recorder_pid
      begin
        Process.kill('TERM', recorder_pid)
      rescue Errno::ESRCH
        # Already exited.
      end
    end
    # The fixture terminates itself after nine seconds (twelve for accessory mode). Wait before removing its
    # temporary bundle, including when the recorder fails partway through.
    Process.wait(launcher) if launcher
  end
end
