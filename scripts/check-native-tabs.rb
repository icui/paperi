#!/usr/bin/ruby
# Opt-in structural investigation, not an assertion of native-tab support.
require 'fileutils'
require 'json'
require 'open3'
require 'timeout'
require 'tmpdir'

root = File.expand_path('..', __dir__)
arguments = ARGV.dup
unvisited = arguments.delete('--unvisited') != nil
restart = arguments.delete('--restart') != nil
content = arguments.delete('--content') != nil
partial = arguments.delete('--partial') != nil
multi = arguments.delete('--multi') != nil || content || partial
abort 'Usage: check-native-tabs.rb [--multi|--content|--unvisited|--restart|--partial] [new-output.json]' if arguments.length > 1 || (unvisited && multi) || (restart && (unvisited || multi)) || (partial && content) || arguments.any? { |argument| argument.start_with?('-') }
wrapper = File.join(root, 'scripts', 'swift.sh')
abort 'Build failed' unless system(wrapper, 'build')
bin, status = Open3.capture2(wrapper, 'build', '--show-bin-path')
abort 'Cannot resolve build directory' unless status.success?
bin = bin.strip
mode_key = if restart then :restart
elsif partial then :partial
elsif unvisited then :unvisited
elsif content then :content
elsif multi then :multi
else :single
end
configuration = {
  restart: ['RestartTab', 'native-tab-restart', 'observer restart'],
  partial: ['PartialTab', 'native-tab-partial', 'independent groups with partial selection metadata'],
  unvisited: ['UnvisitedTab', 'native-tab-unvisited', 'unvisited native member'],
  content: ['ContentTab', 'content-tab', 'native groups with content tabs'],
  multi: ['MultiTab', 'native-tab-multi', 'multiple containers'],
  single: ['NativeTab', 'native-tab', 'single container']
}.fetch(mode_key)
bundle_id = "dev.paperi.#{configuration[0]}Fixture"
filename = "#{configuration[1]}-fixture.json"
output = arguments.first || File.join(root, 'captures', filename)
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
  recorder_args = ['record', restart ? '42' : (unvisited ? '29' : '20'), '--bundle-id', bundle_id, '--tab-evidence']
  recorder_args += ['--restart-after', '18.5'] if restart
  input, stream, recorder = Open3.popen2(File.join(bin, 'paperi'), *recorder_args)
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
    Timeout.timeout(restart ? 55 : (unvisited ? 45 : 35)) do
      loop do
        row = next_record.call
        break if row['event'] == 'recorderReady'
      end
      fixture_args = [log, unvisited ? '--unvisited-tabs' : (multi ? '--multi-tabs' : '--tabs')]
      fixture_args << '--content-tabs' if content
      fixture_args << '--restart-check' if restart
      fixture_args << '--partial-tabs' if partial
      launcher = Process.spawn('/usr/bin/open', '-g', '-n', '-W', app, '--args', *fixture_args)
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
stage_numbers = restart ? [1, 3, 5, 7, 8, 9, 11, 13, 15] : (unvisited ? [1, 3, 5, 7, 9, 10, 11, 13, 15] : [1, 3, 5, 7, 9, 11, 13, 15])
abort 'Fixture did not complete all tab stages' unless stages.length == stage_numbers.length
truth = stages.map { |stage| [stage[:fixture]['event'], stage[:fixture]['tabWindows']] }.to_h
abort 'Fixture stages were incomplete or duplicated' unless truth.keys == stage_numbers.map { |n| "action-#{n}.0" }
ordered_ids = truth.fetch('action-1.0').map { |window| window.fetch('id') }
ids = ordered_ids.sort
expected_count = partial ? 6 : (unvisited ? 3 : (multi ? 5 : 2))
abort 'Fixture window IDs were invalid' unless ids.length == expected_count && ids.uniq.length == expected_count && ids.all? { |id| id > 0 }
expected_members = if unvisited
  [3, 5, 7, 9, 10, 11].map { |n| [n, [[0, 1, 2]]] }.to_h
elsif multi
  second = partial ? [2, 3, 5] : [2, 3]
  { 3 => [[0, 1], second, [4]], 5 => [[0, 1], second, [4]], 7 => [[0, 1], second, [4]],
    9 => [[0], [1], second, [4]], 11 => [[0], [1] + second, [4]] }
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
inventory_complete = true
checks[:physicalRootIdentity] = stages.all? do |stage|
  app_row = stage[:evidence]['applications'].first
  ids_seen = app_row['observedRoots'].map { |index| app_row['nodes'][index]['windowID'] }.sort
  expected = stage[:fixture]['tabWindows'].select { |window| window['visible'] }.map { |window| window['id'] }.sort
  inventory_complete &&= ids_seen == expected
  if restart && stage[:fixture]['event'].delete_prefix('action-').to_f >= 8
    ids_seen.uniq == ids_seen && (ids_seen - expected).empty?
  else
    ids_seen == expected
  end
end
checks[:physicalInventoryComplete] = inventory_complete if restart
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
  if content
    content_owner = stage[:fixture]['contentWindow']
    groups = groups.reject { |group| group['windowID'] == content_owner }
  end
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
checks[:candidateAssociationsSound] = stages.all? do |stage|
  app_row = stage[:evidence]['applications'].first
  candidates = app_row['selectionAssociations']
  permitted = content ? ['observed', 'unavailable', 'conflict'] : ['observed', 'unavailable']
  next false unless candidates && permitted.include?(candidates['status'])
  candidates['groups'].all? do |candidate|
    node = app_row['nodes'].find { |entry| entry['axIdentity'] == candidate['group'] }
    owner = node && node['windowID']
    if content && owner == stage[:fixture]['contentWindow']
      next !candidate['complete'] && candidate['bindings'].length <= 1 &&
        candidate['bindings'].all? { |binding| binding['windowID'] == owner }
    end
    native = stage[:fixture]['tabWindows'].find { |window| window['visible'] && window['selected'] == owner && window['members'].length > 1 }
    next false unless native
    bindings = candidate['bindings']
    learned = bindings.map { |binding| binding['windowID'] }
    controls = bindings.map { |binding| binding['control'] }
    (learned - native['members']).empty? && learned.uniq.length == learned.length &&
      (controls - candidate['controls']).empty? &&
      candidate['unresolvedControls'] == candidate['controls'].reject { |control| controls.include?(control) } &&
      (!candidate['complete'] || learned.sort == native['members'].sort)
  end
end
learned_stage = stages.find { |stage| stage[:fixture]['event'] == (unvisited ? 'action-11.0' : 'action-7.0') }
learned = learned_stage[:evidence]['applications'].first['selectionAssociations']
native_candidates = learned ? learned['groups'].reject { |group| group['quarantined'] || !group['selectionKnown'] } : []
checks[:visitedGroupsLearned] = learned && learned['status'] == 'observed' &&
  native_candidates.length == (multi && !partial ? 2 : 1) && native_candidates.all? { |group| group['complete'] }
if partial
  app_row = learned_stage[:evidence]['applications'].first
  owner = learned_stage[:fixture]['tabWindows'][2]['selected']
  unknown_group = app_row['nodes'].find { |node| node['AXRole'] == 'AXTabGroup' && node['windowID'] == owner }
  unknown_candidate = unknown_group && learned['groups'].find { |group| group['group'] == unknown_group['axIdentity'] }
  checks[:partialGroupWithheld] = !!(unknown_candidate && !unknown_candidate['selectionKnown'] &&
    !unknown_candidate['complete'] && unknown_candidate['bindings'].empty? &&
    unknown_candidate['unresolvedControls'].length == 3 && learned['unavailableGroups'] == [unknown_group['axIdentity']])
  checks[:unrelatedGroupCompletes] = learned['status'] == 'observed' && !learned['quarantined'] &&
    native_candidates.length == 1 && native_candidates[0]['complete'] &&
    native_candidates[0]['bindings'].map { |binding| binding['windowID'] }.sort == ordered_ids.first(2).sort
end
if unvisited
  before_visit = stages.find { |stage| stage[:fixture]['event'] == 'action-7.0' }
  app_row = before_visit[:evidence]['applications'].first
  candidates = app_row['selectionAssociations']
  group = app_row['nodes'].find { |node| node['AXRole'] == 'AXTabGroup' }
  controls = group ? group.fetch('AXTabs')['nodes'].map { |index| app_row['nodes'][index] } : []
  unavailable = candidates['groups'].first
  checks[:unvisitedMemberWithheld] = candidates['status'] == 'unavailable' && candidates['groups'].length == 1 &&
    !unavailable['selectionKnown'] && unavailable['bindings'].empty? && unavailable['unresolvedControls'].length == 3 &&
    !candidates['quarantined'] && controls.length == 3 && controls.count { |control| !control.key?('AXValue') } == 1 &&
    app_row['observedRoots'].any? { |index| app_row['nodes'][index]['windowID'] == ordered_ids[2] }
  first_visit = stages.find { |stage| stage[:fixture]['event'] == 'action-9.0' }[:evidence]['applications'].first
  fresh = first_visit['selectionAssociations']
  fresh_candidate = fresh['groups'].first
  unresolved = controls.find { |control| !control.key?('AXValue') }
  checks[:firstVisitStartsFresh] = !!(fresh['status'] == 'observed' && fresh['groups'].length == 1 && fresh_candidate &&
    !fresh_candidate['complete'] && unresolved && fresh_candidate['bindings'] == [{ 'control' => unresolved['axIdentity'], 'windowID' => ordered_ids[2] }])
  learned_candidate = learned['groups'].first
  checks[:revisitsCompleteSameCandidate] = !!(group && learned_candidate && learned['status'] == 'observed' &&
    app_row['identityScope'] == learned_stage[:evidence]['applications'].first['identityScope'] &&
    group['axIdentity'] == learned_candidate['group'] && controls.map { |control| control['axIdentity'] } == learned_candidate['controls'] &&
    learned_candidate['complete'] && learned_candidate['bindings'].map { |binding| binding['windowID'] }.sort == ids)
end
regrouped_stage = stages.find { |stage| stage[:fixture]['event'] == (unvisited ? 'action-13.0' : 'action-11.0') }
regrouped = regrouped_stage[:evidence]['applications'].first['selectionAssociations']
checks[:regroupingDropsBindings] = regrouped && (content ? ['observed', 'unavailable', 'conflict'] : ['observed', 'unavailable']).include?(regrouped['status']) &&
  regrouped['groups'].all? { |group| !group['complete'] && group['bindings'].length <= 1 }
closed_stage = stages.find { |stage| stage[:fixture]['event'] == 'action-15.0' }
closed_candidates = closed_stage[:evidence]['applications'].first['selectionAssociations']
checks[:closedCandidatesCleared] = closed_candidates && closed_candidates['groups'].empty?
if restart
  after_restart = stages.find { |stage| stage[:fixture]['event'] == 'action-8.0' }[:evidence]['applications'].first
  before_restart = learned_stage[:evidence]['applications'].first
  new_report = after_restart['selectionAssociations']
  checks[:restartDiscardsLearnedBindings] = before_restart['identityScope'] != after_restart['identityScope'] &&
    new_report['status'] == 'observed' && !new_report['quarantined'] && new_report['groups'].length == 1 &&
    new_report['groups'].all? { |group| !group['complete'] && group['bindings'].length == 1 && group['unresolvedControls'].length == 1 }
  restarts = records.select { |row| row['event'] == 'recorderRestarted' }
  checks[:nativeSourcesRemovedAtRestart] = restarts.length == 1 && restarts.first['teardown'] == {
    'detachedObserverCount' => 1, 'sourcesStillInstalled' => 0, 'workspaceObserverCount' => 0 }
  checks[:restartReadyOnce] = records.count { |row| row['event'] == 'recorderReady' } == 2
  window_events = records.select { |row| ['AXWindowCreated', 'AXUIElementDestroyed'].include?(row['event']) }
  checks[:noDuplicateWindowEvents] = window_events.group_by { |row| [row['event'], row['windowID']] }.values.all? { |events| events.length == 1 }
  checks[:windowEventCoverageComplete] = ['AXWindowCreated', 'AXUIElementDestroyed'].all? do |event|
    window_events.select { |row| row['event'] == event }.map { |row| row['windowID'] }.sort == ids
  end
  checks[:finalNativeSourcesRemoved] = records.find { |row| row['event'] == 'recordingEnded' }.dig('teardown', 'sourcesStillInstalled') == 0
end
if content
  checks[:contentSelectionConfirmed] = [1, 3, 5, 7].map do |n|
    stages.find { |stage| stage[:fixture]['event'] == "action-#{n}.0" }[:fixture]['contentTab']
  end == [0, 1, 0, 1]
  checks[:contentAXStructureObserved] = stages.select { |stage| [1, 3, 5, 7].any? { |n| stage[:fixture]['event'] == "action-#{n}.0" } }.all? do |stage|
    stage[:evidence]['applications'].first['nodes'].any? do |node|
      node['AXRole'] == 'AXTabGroup' && node['windowID'] == stage[:fixture]['contentWindow'] && node.dig('AXTabs', 'count') == 2
    end
  end
  checks[:contentNeverComplete] = stages.all? do |stage|
    app_row = stage[:evidence]['applications'].first
    app_row['selectionAssociations']['groups'].none? do |candidate|
      node = app_row['nodes'].find { |entry| entry['axIdentity'] == candidate['group'] }
      candidate['complete'] && node && node['windowID'] == stage[:fixture]['contentWindow']
    end
  end
  checks[:contentRadioSelectionCaptured] = [5, 7].all? do |n|
    stage = stages.find { |entry| entry[:fixture]['event'] == "action-#{n}.0" }
    nodes = stage[:evidence]['applications'].first['nodes']
    group = nodes.find { |node| node['AXRole'] == 'AXTabGroup' && node['windowID'] == stage[:fixture]['contentWindow'] }
    controls = group ? (group.dig('AXTabs', 'nodes') || []).map { |index| nodes[index] } : []
    controls.length == 2 && controls.all? { |node| [true, false].include?(node['AXValue']) } &&
      controls.index { |node| node['AXValue'] == true } == stage[:fixture]['contentTab'] &&
      controls.any? { |node| node['AXValueEncoding'] == 'number01' }
  end
  checks[:contentConflictQuarantined] = stages.select do |stage|
    [7, 9, 11, 13].any? { |n| stage[:fixture]['event'] == "action-#{n}.0" }
  end.all? do |stage|
    report = stage[:evidence]['applications'].first['selectionAssociations']
    report['quarantined'] == true && report['scopeQuarantined'] == false &&
      report['quarantinedGroups'].length == 1 &&
      report['groups'].select { |group| group['quarantined'] }.all? { |group| group['bindings'].empty? && !group['complete'] }
  end
  learned_app = learned_stage[:evidence]['applications'].first
  content_group = learned_app['nodes'].find do |node|
    node['AXRole'] == 'AXTabGroup' && node['windowID'] == learned_stage[:fixture]['contentWindow']
  end
  checks[:onlyContentGroupQuarantined] = content_group && learned['quarantinedGroups'] == [content_group['axIdentity']]
end
structural_checks = checks.reject { |name, _| name == :enumeratedRepresentatives || name == :physicalInventoryComplete }
observation = if structural_checks.values.all?
  restart ? 'native observer restart verified; inactive-member rediscovery may be incomplete' :
    (unvisited ? 'unvisited selection withheld and fresh learning verified; daily-app support unresolved' :
    (content ? 'content-tab negative control verified; app classification unresolved' :
    (checks[:enumeratedRepresentatives] ? 'fixture tab structure verified; member mapping unresolved' :
    'observer tab structure verified; enumeration inconclusive; member mapping unresolved')))
else
  'inconclusive AX coverage'
end
event_counts = records.group_by { |row| row['event'] }.transform_values(&:length)
identity_comparisons = (unvisited ? [[0, 1, 2]] : (multi ? [[0, 1], partial ? [2, 3, 5] : [2, 3]] : [[0, 1]])).map do |indices|
  samples = (unvisited ? [3, 5, 7, 9] : [3, 5, 7]).map do |n|
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
    sample[:scope] && sample[:group] && sample[:controls].length == indices.length &&
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
    selectionAssociationVerified: stable_controls && bindings.length == indices.length &&
      bindings.values.all? { |windows| windows.length == 1 } && bindings.values.flatten.sort == expected_members,
    sameGroupToken: ready ? samples.map { |sample| sample[:group] }.uniq.length == 1 : nil,
    sameOrderedControlTokens: ready ? samples.map { |sample| sample[:controls] }.uniq.length == 1 : nil,
    returnRestoresTokens: ready ? samples.first[:controls] == samples.last[:controls] : nil }
end
File.write(output, JSON.pretty_generate(schemaVersion: 11, fixtureMode: configuration[2], observation: observation, checks: checks, identityComparisons: identity_comparisons,
  discoveryPasses: records.select { |row| row['event'] == 'windowDiscovery' }, stages: stages, events: event_counts,
  scope: 'Controlled fixture evidence only. Native-tab grouping is not inferred from equal frames or titles.'))
summary = stages.map do |stage|
  apps = stage[:evidence]['applications']
  nodes = apps.flat_map { |app| app['nodes'] }
  { stage: stage[:fixture]['event'], truth: stage[:fixture]['tabWindows'],
    axWindowIDs: nodes.select { |node| node.key?('enumeratedWindowIndex') }.map { |node| node['windowID'] },
    observedWindowIDs: nodes.select { |node| node.key?('observedWindowIndex') }.map { |node| node['windowID'] },
    windowsErrors: apps.map { |app| app['windowsError'] },
    candidateAssociations: apps.map { |app| app['selectionAssociations'] },
    tabControls: nodes.select { |node| ['AXTabGroup', 'AXRadioButton'].include?(node['AXRole']) }.map do |node|
      node.select { |key, _| ['node', 'AXRole', 'AXValue', 'AXSelected', 'AXChildren', 'AXSelectedChildren', 'AXWindow'].include?(key) }
    end,
    truncated: apps.any? { |app| app['truncated'] } }
end
puts JSON.pretty_generate(output: output, observation: observation, checks: checks,
                          identityComparisons: identity_comparisons, events: event_counts, stages: summary)
