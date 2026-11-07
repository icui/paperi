#!/usr/bin/ruby
# Opt-in structural investigation, not an assertion of native-tab support.
require 'fileutils'
require 'json'
require 'open3'
require 'timeout'
require 'tmpdir'

root = File.expand_path('..', __dir__)
arguments = ARGV.dup
multi = arguments.delete('--multi') != nil
abort 'Usage: check-native-tabs.rb [--multi] [new-output.json]' if arguments.length > 1
wrapper = File.join(root, 'scripts', 'swift.sh')
abort 'Build failed' unless system(wrapper, 'build')
bin, status = Open3.capture2(wrapper, 'build', '--show-bin-path')
abort 'Cannot resolve build directory' unless status.success?
bin = bin.strip
bundle_id = multi ? 'dev.paperi.MultiTabFixture' : 'dev.paperi.NativeTabFixture'
output = arguments.first || File.join(root, 'captures', multi ? 'native-tab-multi-fixture.json' : 'native-tab-fixture.json')
abort "Output already exists: #{output}" if File.exist?(output)
stages = []
records = []

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
  input, stream, recorder = Open3.popen2(File.join(bin, 'paperi'), 'record', '20',
                                      '--bundle-id', bundle_id, '--tab-evidence')
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
    abort 'Recorder ended before evidence was collected' unless row
    raise row if row.is_a?(Exception)
    records << row
    row
  end
  launcher = nil
  consumed = 0
  begin
    Timeout.timeout(35) do
      loop do
        row = next_record.call
        break if row['event'] == 'recorderReady'
      end
      launcher = Process.spawn('/usr/bin/open', '-g', '-n', '-W', app, '--args', log, multi ? '--multi-tabs' : '--tabs')
      loop do
        rows = File.exist?(log) ? File.readlines(log).map { |line| JSON.parse(line) } : []
        rows.drop(consumed).each do |row|
          if row.fetch('event').start_with?('action-')
            # Use the same observer session throughout. Wait for a structural
            # sample collected after this action, not an earlier cached report.
            evidence = loop do
              candidate = next_record.call
              break candidate if candidate['event'] == 'tabEvidence' && candidate['captureStartedUptime'] >= row.fetch('uptime') + 0.15
            end
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
      loop do
        break if next_record.call['event'] == 'recordingEnded'
      end
      abort 'Observer recorder failed' unless recorder.value.success?
    end
  ensure
    Process.kill('TERM', recorder.pid) if recorder.alive?
    recorder.value
    reader.join
    stream.close
    Process.wait(launcher) if launcher
  end
end
abort 'Fixture did not complete all eight tab stages' unless stages.length == 8
truth = stages.map { |stage| [stage[:fixture]['event'], stage[:fixture]['tabWindows']] }.to_h
abort 'Fixture stages were incomplete or duplicated' unless truth.keys == [1, 3, 5, 7, 9, 11, 13, 15].map { |n| "action-#{n}.0" }
ordered_ids = truth.fetch('action-1.0').map { |window| window.fetch('id') }
ids = ordered_ids.sort
expected_count = multi ? 5 : 2
abort 'Fixture window IDs were invalid' unless ids.length == expected_count && ids.uniq.length == expected_count && ids.all? { |id| id > 0 }
expected_members = if multi
  { 3 => [[0, 1], [2, 3], [4]], 5 => [[0, 1], [2, 3], [4]], 7 => [[0, 1], [2, 3], [4]],
    9 => [[0], [1], [2, 3], [4]], 11 => [[0], [1, 2, 3], [4]] }
else
  { 3 => [[0, 1]], 5 => [[0, 1]], 7 => [[0, 1]], 9 => [[0], [1]], 11 => [[0, 1]] }
end
expected_members.each do |n, containers|
  rows = truth.fetch("action-#{n}.0")
  containers.each do |indices|
    expected = indices.map { |index| ordered_ids[index] }.sort
    indices.each do |index|
      actual = rows[index]['members']
      actual = [rows[index]['id']] if actual.empty?
      abort "Native membership was not confirmed at stage #{n}" unless actual.sort == expected
    end
  end
end
selection_pairs = multi ? [[0, 1], [2, 3]] : [[0, 1]]
selection_pairs.each do |first, second|
  abort 'Native selection was not confirmed' unless truth.fetch('action-5.0')[first]['selected'] == ordered_ids[second] &&
                                                       truth.fetch('action-7.0')[first]['selected'] == ordered_ids[first]
end
abort 'Native close was not confirmed' unless truth.fetch('action-13.0').count { |window| window['visible'] } == expected_count - 1 &&
                                                truth.fetch('action-15.0').none? { |window| window['visible'] }
closed = ids - truth.fetch('action-13.0').select { |window| window['visible'] }.map { |window| window['id'] }
expected_closed = truth.fetch('action-11.0')[multi ? 2 : 0]['selected']
abort 'The selected native member was not the one closed' unless closed == [expected_closed]
if multi
  abort 'Independent fixture window joined a tab group or closed early' unless [1, 3, 5, 7, 9, 11, 13].all? do |n|
    independent = truth.fetch("action-#{n}.0")[4]
    independent['visible'] && independent['members'].empty?
  end
end
FileUtils.mkdir_p(File.dirname(output))
complete = stages.all? do |stage|
  apps = stage[:evidence]['applications']
  visible = stage[:fixture]['tabWindows'].any? { |window| window['visible'] }
  stage[:stageStillCurrent] && apps.all? do |app|
    app['windowsError'] == 0 && !app['truncated'] && (!visible || !(app['roots'] + app['observedRoots']).empty?)
  end
end
checks = { stageCoverage: complete }
checks[:physicalRootIdentity] = stages.all? do |stage|
  app_row = stage[:evidence]['applications'].first
  ids_seen = app_row['observedRoots'].map { |index| app_row['nodes'][index]['windowID'] }.sort
  expected = stage[:fixture]['tabWindows'].select { |window| window['visible'] }.map { |window| window['id'] }.sort
  ids_seen == expected
end
checks[:enumeratedRepresentatives] = stages.all? do |stage|
  app_row = stage[:evidence]['applications'].first
  nodes = app_row['nodes']
  visible = stage[:fixture]['tabWindows'].select { |window| window['visible'] }
  containers = visible.group_by { |window| window['members'].empty? ? [window['id']] : window['members'].sort }
  representatives = containers.values.map { |members| members.first['selected'] > 0 ? members.first['selected'] : members.first['id'] }.sort
  app_row['roots'].map { |index| nodes[index]['windowID'] }.sort == representatives
end
checks[:tabGroupOwnershipAndSelection] = stages.all? do |stage|
  app_row = stage[:evidence]['applications'].first
  nodes = app_row['nodes']
  groups = nodes.select { |node| node['AXRole'] == 'AXTabGroup' }
  visible = stage[:fixture]['tabWindows'].select { |window| window['visible'] }
  containers = visible.group_by { |window| window['members'].empty? ? [window['id']] : window['members'].sort }
  tabbed = containers.select { |members, _| members.length > 1 }
  next false unless groups.length == tabbed.length
  tabbed.all? do |members, windows|
    selected = windows.first['selected']
    owned_groups = groups.select do |group|
      (group.dig('AXWindow', 'nodes') || []).any? { |index| nodes[index]['windowID'] == selected }
    end
    next false unless owned_groups.length == 1
    tabs = owned_groups.first.fetch('AXTabs', {})
    controls = (tabs['nodes'] || []).map { |index| nodes[index] }
    tabs['error'] == 0 && tabs['count'] == members.length && controls.length == members.length &&
      controls.all? { |node| node['AXSubrole'] == 'AXTabButton' } && controls.count { |node| node['AXValue'] == true } == 1
  end
end
checks[:confirmedDestruction] = records.count { |row| row['event'] == 'AXUIElementDestroyed' } == expected_count
structural_checks = checks.reject { |name, _| name == :enumeratedRepresentatives }
observation = if structural_checks.values.all?
  checks[:enumeratedRepresentatives] ? 'fixture tab structure verified; member mapping unresolved' :
    'observer tab structure verified; enumeration inconclusive; member mapping unresolved'
else
  'inconclusive AX coverage'
end
event_counts = records.group_by { |row| row['event'] }.transform_values(&:length)
identity_comparisons = (multi ? [[0, 1], [2, 3]] : [[0, 1]]).map do |indices|
  samples = [3, 5, 7].map do |n|
    stage = stages.find { |entry| entry[:fixture]['event'] == "action-#{n}.0" }
    app_row = stage[:evidence]['applications'].first
    nodes = app_row['nodes']
    selected = stage[:fixture]['tabWindows'][indices.first]['selected']
    group = nodes.find { |node| node['AXRole'] == 'AXTabGroup' && node['windowID'] == selected }
    controls = group ? (group.dig('AXTabs', 'nodes') || []).map { |index| nodes[index] } : []
    { stage: n, scope: app_row['identityScope'], group: group && group['axIdentity'],
      controls: controls.map { |node| node['axIdentity'] }, selectedWindow: selected,
      observedWindow: group && group['windowID'],
      selectedControls: controls.select { |node| node['AXValue'] == true }.map { |node| node['axIdentity'] },
      truncated: app_row['identityTruncated'] || app_row['truncated'] }
  end
  ready = checks[:tabGroupOwnershipAndSelection] && samples.all? do |sample|
    sample[:scope] && sample[:group] && sample[:controls].length == 2 &&
      sample[:observedWindow].is_a?(Integer) && sample[:observedWindow] > 0 &&
      sample[:controls].none?(&:nil?) && sample[:selectedControls].length == 1 && !sample[:truncated]
  end && samples.map { |sample| sample[:scope] }.uniq.length == 1
  bindings = ready ? samples.group_by { |sample| sample[:selectedControls].first }.transform_values do |selected_samples|
    selected_samples.map { |sample| sample[:observedWindow] }.uniq
  end : {}
  stable_controls = ready && samples.map { |sample| sample[:group] }.uniq.length == 1 &&
    samples.map { |sample| sample[:controls] }.uniq.length == 1
  expected_members = indices.map { |index| ordered_ids[index] }.sort
  { fixtureMemberIDs: expected_members, comparable: ready, samples: samples,
    selectedControlBindings: bindings,
    selectionAssociationVerified: stable_controls && bindings.length == 2 &&
      bindings.values.all? { |windows| windows.length == 1 } && bindings.values.flatten.sort == expected_members,
    sameGroupToken: ready ? samples.map { |sample| sample[:group] }.uniq.length == 1 : nil,
    sameOrderedControlTokens: ready ? samples.map { |sample| sample[:controls] }.uniq.length == 1 : nil,
    returnRestoresTokens: ready ? samples.first[:controls] == samples.last[:controls] : nil }
end
File.write(output, JSON.pretty_generate(schemaVersion: 4, fixtureMode: multi ? 'multiple containers' : 'single container', observation: observation, checks: checks, identityComparisons: identity_comparisons, stages: stages, events: event_counts,
  scope: 'Controlled fixture evidence only. Native-tab grouping is not inferred from equal frames or titles.'))
summary = stages.map do |stage|
  apps = stage[:evidence]['applications']
  nodes = apps.flat_map { |app| app['nodes'] }
  { stage: stage[:fixture]['event'], truth: stage[:fixture]['tabWindows'],
    axWindowIDs: nodes.select { |node| node.key?('enumeratedWindowIndex') }.map { |node| node['windowID'] },
    observedWindowIDs: nodes.select { |node| node.key?('observedWindowIndex') }.map { |node| node['windowID'] },
    windowsErrors: apps.map { |app| app['windowsError'] },
    tabControls: nodes.select { |node| ['AXTabGroup', 'AXRadioButton'].include?(node['AXRole']) }.map do |node|
      node.select { |key, _| ['node', 'AXRole', 'AXValue', 'AXSelected', 'AXChildren', 'AXSelectedChildren', 'AXWindow'].include?(key) }
    end,
    truncated: apps.any? { |app| app['truncated'] } }
end
puts JSON.pretty_generate(output: output, observation: observation, checks: checks,
                          identityComparisons: identity_comparisons, events: event_counts, stages: summary)
