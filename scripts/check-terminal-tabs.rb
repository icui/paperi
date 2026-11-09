#!/usr/bin/ruby
# Read-only adapter evidence; UI/scripting actions target one owned Terminal window.
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'timeout'
require 'securerandom'

placement = ARGV.delete('--placement') != nil
resize = ARGV.delete('--resize') != nil
session = ARGV.delete('--session') != nil
abort 'Usage: check-terminal-tabs.rb [--placement|--resize|--session] new-output-directory' unless ARGV.length == 1 && [placement, resize, session].count(true) <= 1
placement ||= resize
root = File.expand_path('..', __dir__)
output = File.expand_path(ARGV.first)
abort "Output exists: #{output}" if File.exist?(output)
FileUtils.mkdir_p(output)
wrapper = File.join(root, 'scripts', 'swift.sh')
abort 'Build failed' unless system(wrapper, 'build')
bin, status = Open3.capture2(wrapper, 'build', '--show-bin-path')
abort 'Cannot locate binary' unless status.success?
token = "Paperi-test-#{SecureRandom.uuid}"
report = { schemaVersion: 1, scope: 'Owned Terminal two-tab window; no geometry or existing-window writes', tabSupport: 'unverified', ownershipTag: token }
report[:scope] = 'Owned Terminal native representatives; guarded translation/restoration' if placement
report[:scope] = 'Owned Terminal native representatives; measured cell-grid resize/restoration' if resize
report[:scope] = 'Sustained shared-session Terminal native-tab lifecycle; switch, growth, active/last close' if session
records = []
owned = nil

Dir.mktmpdir('paperi-terminal-', File.join(root, '.build')) do |temporary|
  script = File.join(temporary, 'terminal.applescript')
  File.write(script, <<~APPLESCRIPT)
    on findTabCommand(theMenu)
      tell application "System Events"
        repeat with menuItem in menu items of theMenu
          try
            if value of attribute "AXMenuItemCmdChar" of menuItem is "t" and value of attribute "AXMenuItemCmdModifiers" of menuItem is 0 then return contents of menuItem
          end try
          try
            set found to my findTabCommand(menu 1 of menuItem)
            if found is not missing value then return found
          end try
        end repeat
      end tell
      return missing value
    end findTabCommand

    on run argv
      set actionName to item 1 of argv
      set tagName to item 2 of argv
      with timeout of 10 seconds
        if actionName is "create" then
          tell application "Terminal"
            set testTab to do script ":"
            set custom title of testTab to tagName
            set testTTY to tty of testTab
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is testTTY then
                  if (count tabs of w) is not 1 then error "New window unexpectedly contains other tabs"
                  return id of w
                end if
              end repeat
            end repeat
          end tell
          error "Cannot identify newly created window"
        end if
        if actionName is "close-tagged" then
          tell application "Terminal"
            repeat
              set closeTarget to missing value
              repeat with w in (get windows)
              set tagged to false
              set allOwned to true
              repeat with t in tabs of w
                if custom title of t is tagName then
                  set tagged to true
                else
                  set allOwned to false
                end if
              end repeat
              if tagged then
                if not allOwned then error "Test group contains an unowned tab"
                repeat with t in tabs of w
                  if busy of t then error "Owned tab is busy; refusing to close"
                end repeat
                set closeTarget to contents of w
                exit repeat
              end if
              end repeat
              if closeTarget is missing value then exit repeat
              close closeTarget saving no
            end repeat
          end tell
          return "closed"
        end if
        set wid to (item 3 of argv) as integer
        tell application "Terminal"
          if not (exists window id wid) then
            if actionName is "close" then return "closed"
            error "Owned test window disappeared"
          end if
          set w to window id wid
          repeat with t in tabs of w
            if custom title of t is not tagName then error "Window contains an unowned tab"
          end repeat
          if actionName is "close" then
            repeat with t in tabs of w
              if busy of t then error "Owned tab is busy; refusing to close"
            end repeat
            close w saving no
            return "closed"
          end if
          if actionName is "close-selected-tab" then
            set index of w to 1
            activate
            delay 0.15
            if id of front window is not wid then error "Physical test representative not selected"
            if custom title of selected tab of front window is not tagName then error "Selected representative is unowned"
            if busy of selected tab of front window then error "Selected tab is busy; refusing to close"
            close window id wid saving no
            delay 0.35
            return "closed"
          end if
          if actionName is "select" then
            set index of w to 1
            activate
            delay 0.2
            if id of front window is not wid then error "Physical test representative not selected"
            if custom title of selected tab of front window is not tagName then error "Selected representative is unowned"
            return id of front window
          end if
          if actionName is not "new-tab" then error "Unknown test action"
          set index of w to 1
          activate
          delay 0.2
          if id of front window is not wid then error "Test window is not frontmost"
          set previousIDs to id of every window
        end tell
        set candidate to missing value
        tell application "System Events" to tell process "Terminal"
          repeat with barItem in menu bar items of menu bar 1
            try
              set found to my findTabCommand(menu 1 of barItem)
              if found is not missing value then
                set candidate to found
                exit repeat
              end if
            end try
          end repeat
        end tell
        if candidate is missing value then error "New Tab menu command unavailable"
        tell application "Terminal"
          set index of w to 1
          activate
          delay 0.1
          if id of front window is not wid then error "Test window lost command ownership"
        end tell
        tell application "System Events" to click candidate
        delay 0.7
        tell application "Terminal"
          activate
          set activeID to id of front window
          if activeID is in previousIDs and activeID is not wid then error "Unexpected preexisting window after New Tab"
          set custom title of selected tab of front window to tagName
          return activeID
        end tell
      end timeout
    end run
  APPLESCRIPT
  run = lambda do |action, *args|
    value, error, result = Open3.capture3('/usr/bin/osascript', script, action, token, *args.map(&:to_s))
    raise "#{action} failed: #{error.strip}" unless result.success?
    value.strip
  end
  recorder = nil
  reader = nil
  stream = nil
  begin
    id = run.call('create')
    raise 'Invalid created window identity' unless id.match?(/\A[1-9]\d*\z/)
    owned = id.to_i
    report[:ownedWindowID] = owned
    active = run.call('new-tab', owned)
    raise 'Invalid selected new representative' unless active.match?(/\A[1-9]\d*\z/)
    targets = [owned, active.to_i]
    report[:testRepresentativeIDs] = targets
    if session
      input, stream, recorder = Open3.popen2(File.join(bin.strip, 'paperi'), 'probe-terminal-session', token)
      input.close
      queue = Queue.new
      reader = Thread.new do
        buffer = +''
        begin
          stream.each_line do |line|
            if line.start_with?('{') && line.include?('"event"')
              queue << JSON.parse(line)
            else
              buffer << line
            end
          end
          queue << JSON.parse(buffer) unless buffer.strip.empty?
        rescue StandardError => error
          queue << error
        ensure
          queue << nil
        end
      end
      take_event = lambda do |expected, active = nil, count = nil|
        loop do
          row = queue.pop
          raise "Session ended before #{expected}" unless row
          raise row if row.is_a?(Exception)
          records << row
          next unless row['event'] == expected
          if active
            entry = row['entry'] || {}
            parts = entry['partitions']
            actual_active = entry['active'] || parts&.first&.dig('active')
            actual_count = (entry['members'] || parts&.first&.dig('members') || []).length
            next unless actual_active == active && (count.nil? || actual_count == count)
          end
          return row
        end
      end
      Timeout.timeout(65) do
        take_event.call('terminalSessionReady')
        run.call('select', targets[0])
        sleep 0.6
        run.call('select', targets[1])
        take_event.call('terminalSessionAdmitted', targets[1], 2)
        run.call('select', targets[0])
        take_event.call('terminalSessionReconciled', targets[0], 2)
        run.call('select', targets[1])
        take_event.call('terminalSessionReconciled', targets[1], 2)
        run.call('select', targets[0])
        take_event.call('terminalSessionReconciled', targets[0], 2)
        third = run.call('new-tab', targets[0]).to_i
        raise 'Invalid third representative' unless third > 0
        targets << third
        report[:testRepresentativeIDs] = targets
        sleep 0.6
        run.call('select', targets[0])
        sleep 0.6
        run.call('select', targets[1])
        sleep 0.6
        run.call('select', third)
        take_event.call('terminalSessionReconciled', third, 3)
        run.call('close-selected-tab', third)
        sleep 0.6
        run.call('select', targets[0])
        sleep 0.6
        run.call('select', targets[1])
        take_event.call('terminalSessionReconciled', targets[1], 2)
        run.call('close-selected-tab', targets[1])
        sleep 0.6
        run.call('select', targets[0])
        take_event.call('terminalSessionReconciled', targets[0], 1)
        run.call('close-selected-tab', targets[0])
        take_event.call('terminalSessionEmptied')
        loop do
          row = queue.pop
          break unless row
          raise row if row.is_a?(Exception)
          records << row
        end
        raise 'Session probe exited non-zero' unless recorder.value.success?
      end
      session_report = records.reverse.find { |r| r.is_a?(Hash) && r.key?('checks') }
      raise 'Missing final session report' unless session_report
      report[:sessionReport] = session_report
      report[:checks] = session_report['checks'].transform_keys(&:to_sym)
      report[:sharedMembershipVerified] = report[:checks][:admittedInitialPair] && report[:checks][:newMemberAdmitted]
      report[:tabSupport] = report[:checks].values.all? { |v| v == true } ? 'verifiedInOwnedSession' : 'unverified'
    else
      input, stream, recorder = Open3.popen2(File.join(bin.strip, 'paperi'), 'record', placement ? '40' : '20', '--bundle-id', 'com.apple.Terminal', '--tab-evidence')
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
    take = lambda do
      row = queue.pop
      raise 'Recorder ended before all stages' unless row
      raise row if row.is_a?(Exception)
      records << row
      row
    end
    report[:stages] = []
    selection = [targets[0], targets[1], targets[0]] * (placement ? 2 : 1)
    Timeout.timeout(placement ? 65 : 35) do
      loop { break if take.call['event'] == 'recorderReady' }
      selection.each_with_index do |target, index|
        if placement && index == 3
          baseline = report[:stages][2][:memberships].any? do |candidate|
            candidate['members'].sort == targets.sort && candidate['active'] == targets.first
          end
          raise 'Exact owned native baseline unavailable; no geometry effects attempted' unless baseline
        end
        identity = run.call('select', target)
        effect = nil
        if placement && index >= 3
          command = resize ? 'probe-terminal-resize' : 'probe-terminal-placement'
          value, error, status = Open3.capture3(File.join(bin.strip, 'paperi'), command, target.to_s, token)
          effect = JSON.parse(value)
          raise "Placement failed: #{error.strip} #{value}" unless status.success?
        end
        # Drain reports already completed before the selection, then wait for
        # two samples so the selected evidence cannot predate the action.
        loop do
          row = queue.pop(true) rescue nil
          break unless row
          raise row if row.is_a?(Exception)
          records << row
        end
        fresh = []
        until fresh.length == 2
          row = take.call
          fresh << row if row['event'] == 'tabEvidence'
        end
        evidence = fresh.last.fetch('nativeTabEvidence')
        app = evidence.fetch('applications').first
        raise 'Terminal not discovered' unless app
        nodes = app.fetch('nodes')
        report[:stages] << {
          selectedTab: index + 1, scriptIdentity: identity, target: target, captureScope: evidence['captureScope'],
          coverage: app['windowCoverage'], rootValidations: app['rootValidations'],
          ownedRoots: app.fetch('roots').map { |i| nodes[i]['windowID'] }.select { |wid| targets.include?(wid) },
          controls: nodes.select { |n| targets.include?(n['windowID']) && %w[AXTabGroup AXRadioButton].include?(n['AXRole']) },
          associations: app['selectionAssociations'], memberships: app['membershipCandidates'], placement: effect
        }
      end
      loop { break if take.call['event'] == 'recordingEnded' }
      raise 'Recorder failed' unless recorder.value.success?
    end
    report[:checks] = {
      scriptSelectionConfirmed: report[:stages].map { |s| s[:scriptIdentity] } == selection.map(&:to_s),
      ownedRootObserved: report[:stages].all? { |s| s[:ownedRoots].include?(s[:target]) },
      sharedCaptureScope: report[:stages].all? { |s| s[:captureScope] == 'directWindowTabBar' },
      sourcesRemoved: records.last.dig('teardown', 'sourcesStillInstalled') == 0
    }
    report[:sharedMembershipVerified] = report[:stages].last[:memberships].any? do |candidate|
      candidate['members'].sort == targets.sort && candidate['active'] == targets.first
    end
      if placement
        report[:checks][:placementsRestored] = report[:stages].drop(3).all? { |s| s[:placement]['result'] == 'passed' }
        report[:checks][:nativeMembershipRetained] = report[:sharedMembershipVerified]
        report[:checks][:baselineNativeMembershipLearned] = report[:stages][2][:memberships].any? do |candidate|
          candidate['members'].sort == targets.sort && candidate['active'] == targets.first
        end
        report[:checks][:gridColumnsRestored] = report[:stages].drop(3).all? do |stage|
          stage[:placement]['calibrationRestored'] && stage[:placement]['gridColumnsConfirmed']
        end if resize
      end
    end
  rescue StandardError => error
    report[:error] = error.message
  ensure
    if recorder
      Process.kill('TERM', recorder.pid) if recorder.alive?
      recorder.value
      reader.join if reader
      stream.close if stream
    end
    begin
      report[:cleanup] = run.call('close-tagged')
    rescue StandardError => error
      report[:cleanupError] = error.message
    end
    File.write(File.join(output, 'capture.jsonl'), records.map { |r| JSON.generate(r) }.join("\n") + "\n")
    report[:result] = report[:error].nil? && report[:cleanup] == 'closed' && report.fetch(:checks, {}).values.all? { |v| v == true } ? 'passed' : 'failed'
    File.write(File.join(output, 'summary.json'), JSON.pretty_generate(report))
  end
end
puts JSON.pretty_generate(report)
exit(report[:result] == 'passed' ? 0 : 1)
