require 'minitest/autorun'
require_relative '../../scripts/window-event-evidence'

class WindowEventEvidenceTest < Minitest::Test
  def test_unknown_events_do_not_establish_duplicates_or_complete_coverage
    records = [0, 0, nil, '101'].map { |id| { 'event' => 'AXWindowCreated', 'windowID' => id } }
    report = WindowEventEvidence.summarize(records, expected_ids: [101, 102])
    assert_empty report[:duplicateKnownEvents]
    assert_equal 4, report[:unresolvedIdentityEventCount]
    refute report[:identitiesComplete]
    refute report[:coverageComplete]
  end

  def test_known_duplicates_are_reported_even_beside_unresolved_events
    records = [101, 101, 0].map { |id| { 'event' => 'AXWindowCreated', 'windowID' => id } }
    report = WindowEventEvidence.summarize(records, expected_ids: [101])
    assert_equal [{ event: 'AXWindowCreated', windowID: 101, count: 2 }], report[:duplicateKnownEvents]
    refute report[:identitiesComplete]
    refute report[:coverageComplete]
  end

  def test_each_expected_identity_requires_both_create_and_destroy
    records = [101, 102].flat_map do |id|
      %w[AXWindowCreated AXUIElementDestroyed].map { |event| { 'event' => event, 'windowID' => id } }
    end
    records << { 'event' => 'AXMoved', 'windowID' => 0 }
    report = WindowEventEvidence.summarize(records, expected_ids: [101, 102])
    assert_empty report[:duplicateKnownEvents]
    assert report[:identitiesComplete]
    assert report[:coverageComplete]
    missing = records.reject { |row| row['event'] == 'AXUIElementDestroyed' && row['windowID'] == 102 }
    report = WindowEventEvidence.summarize(missing, expected_ids: [101, 102])
    assert report[:identitiesComplete]
    refute report[:coverageComplete]
  end
end
