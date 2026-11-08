#!/usr/bin/ruby
# Real-app discovery spike only. Creates/closes only its own Finder windows;
# never merges windows, changes preferences, or reads document titles/content.
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

root = File.expand_path('..', __dir__)
new_tab = ARGV.delete('--new-tab') != nil
abort 'Usage: check-finder-documents.rb [--new-tab] new-output-directory' unless ARGV.length == 1
output = File.expand_path(ARGV.first)
abort "Output exists: #{output}" if File.exist?(output)
FileUtils.mkdir_p(output)
wrapper = File.join(root, 'scripts', 'swift.sh')
abort 'Build failed' unless system(wrapper, 'build')
bin, status = Open3.capture2(wrapper, 'build', '--show-bin-path')
abort 'Cannot locate binary' unless status.success?
bin = bin.strip
owned = []
cleanup_ids = []
report = { schemaVersion: 1, scope: 'Finder document discovery only; native tabs and window management remain unverified' }

Dir.mktmpdir('paperi-finder-', File.join(root, '.build')) do |temporary|
  create = File.join(temporary, 'create.applescript')
  close = File.join(temporary, 'close.applescript')
  File.write(create, <<~APPLESCRIPT)
    on run argv
      tell application "Finder"
        with timeout of 10 seconds
          set w to make new Finder window to (POSIX file (item 1 of argv) as alias)
          return id of w
        end timeout
      end tell
    end run
  APPLESCRIPT
  File.write(close, <<~APPLESCRIPT)
    on run argv
      set wid to (item 1 of argv) as integer
      tell application "Finder"
        with timeout of 10 seconds
          if exists (window id wid) then close (window id wid)
          return not (exists (window id wid))
        end timeout
      end tell
    end run
  APPLESCRIPT
  begin
    %w[First Second].each do |name|
      folder = File.join(temporary, name)
      FileUtils.mkdir_p(folder)
      text, error, result = Open3.capture3('/usr/bin/osascript', create, folder)
      raise "Cannot create scoped Finder document: #{error.strip}" unless result.success? && text.strip.match?(/\A[1-9]\d*\z/)
      owned << text.to_i
      cleanup_ids << text.to_i
    end
    report[:createdWindowIDs] = owned
    expected = owned.dup
    if new_tab
      tab_script = File.join(temporary, 'new-tab.applescript')
      File.write(tab_script, <<~APPLESCRIPT)
        on run argv
          set wid to (item 1 of argv) as integer
          with timeout of 10 seconds
            tell application "Finder"
              set index of (window id wid) to 1
              activate
              if id of front window is not wid then error "Test window is not frontmost"
              set previousIDs to id of every window
            end tell
            set candidate to missing value
            tell application "System Events" to tell process "Finder"
              repeat with barItem in menu bar items of menu bar 1
                try
                  repeat with menuItem in menu items of menu 1 of barItem
                    try
                      if value of attribute "AXMenuItemCmdChar" of menuItem is "t" and value of attribute "AXMenuItemCmdModifiers" of menuItem is 0 then set candidate to contents of menuItem
                    end try
                  end repeat
                end try
              end repeat
            end tell
            if candidate is missing value then error "New Tab command shortcut not exposed"
            tell application "Finder"
              if id of front window is not wid then error "Test window lost command ownership"
            end tell
            tell application "System Events" to click candidate
            delay 0.5
            tell application "Finder"
              set activeID to id of front window
              if activeID is in previousIDs and activeID is not wid then error "Unexpected preexisting active window"
              return activeID
            end tell
          end timeout
        end run
      APPLESCRIPT
      value, error, status = Open3.capture3('/usr/bin/osascript', tab_script, owned.first.to_s)
      raise "Scoped New Tab attempt failed: #{error.strip}" unless status.success? && value.strip.match?(/\A[1-9]\d*\z/)
      active = value.to_i
      cleanup_ids << active unless cleanup_ids.include?(active)
      expected = [active, owned.last]
      report[:newTabCommandCompleted] = true
      report[:activeTestWindowID] = active
    end
    records, error, result = Open3.capture3(File.join(bin, 'paperi'), 'record', '5', '--bundle-id', 'com.apple.finder',
                                          '--tab-evidence', '--window-evidence')
    File.write(File.join(output, 'capture.jsonl'), records)
    raise "Recorder failed: #{error.strip}" unless result.success?
    rows = records.lines.map { |line| JSON.parse(line) }
    tab_apps = rows.select { |row| row['event'] == 'tabEvidence' }.flat_map { |row| row.fetch('applications') }
    policy_apps = rows.select { |row| row['event'] == 'windowEvidence' }.flat_map { |row| row.fetch('applications') }
    report[:shallowTabBarSamples] = rows.select { |row| row['event'] == 'tabEvidence' }
      .flat_map { |row| row.dig('finderTabBarEvidence', 'applications') || [] }.map do |app|
        { nodeCount: app.fetch('nodes').length, truncated: app['truncated'],
          rootValidations: app['rootValidations'], truncationReasons: app['truncationReasons'],
          tabGroupControlCounts: app.fetch('nodes').select { |node| node['AXRole'] == 'AXTabGroup' }
            .map { |node| node.dig('AXTabs', 'count') },
          associations: app['selectionAssociations'] }
      end
    report[:samples] = tab_apps.map do |app|
      { coverage: app['windowCoverage'], rootValidations: app['rootValidations'],
        observedOwnedIDs: app.fetch('nodes').map { |node| node['windowID'] }.compact & expected,
        truncationReasons: app['truncationReasons'],
        tabGroupControlCounts: app.fetch('nodes').select { |node| node['AXRole'] == 'AXTabGroup' }
          .map { |node| node.dig('AXTabs', 'count') || node.dig('AXChildren', 'count') },
        associationStatus: app.dig('selectionAssociations', 'status'),
        issues: app.dig('selectionAssociations', 'evidenceIssues') }
    end
    policy_windows = policy_apps.flat_map { |app| app.fetch('windows') }
    report[:ownedPolicy] = policy_windows.select { |window| expected.include?(window['windowID']) }
      .map { |window| window.select { |key, _| %w[windowID eligibility reason facts].include?(key) } }.uniq
    report[:checks] = {
      twoCreatedIDs: owned.length == 2 && owned.uniq.length == 2,
      ownedWindowsObserved: !tab_apps.empty? && report[:samples].all? { |sample| sample[:observedOwnedIDs].sort == expected.sort },
      ownedWindowsEligible: expected.all? { |id| report[:ownedPolicy].any? { |window| window['windowID'] == id && window['eligibility'] == 'tiled' } },
      nativeSourcesRemoved: rows.last.dig('teardown', 'sourcesStillInstalled') == 0
    }
    report[:tabSupport] = 'unverified'
    report[:tabCaptureAvailable] = !report[:samples].empty? && report[:samples].all? { |sample| sample[:associationStatus] != 'unavailable' }
  rescue StandardError => error
    report[:error] = error.message
  ensure
    report[:createdWindowIDs] = owned
    report[:cleanup] = cleanup_ids.reverse.map do |id|
      value, error, status = Open3.capture3('/usr/bin/osascript', close, id.to_s)
      { windowID: id, closed: status.success? && value.strip == 'true', error: error.strip }
    end
    report[:result] = report[:error].nil? && report.fetch(:checks, {}).values.all? { |value| value == true } &&
      report[:cleanup].length >= 2 && report[:cleanup].all? { |row| row[:closed] } ? 'passed' : 'incomplete or failed'
    File.write(File.join(output, 'summary.json'), JSON.pretty_generate(report))
  end
end
puts JSON.pretty_generate(report)
exit(report[:result] == 'passed' ? 0 : 1)
