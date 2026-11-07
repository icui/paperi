# Unknown physical identities cannot establish either unique or duplicate delivery.
module WindowEventEvidence
  NAMES = %w[AXWindowCreated AXUIElementDestroyed].freeze

  def self.summarize(records, expected_ids:)
    events = records.select { |row| NAMES.include?(row['event']) }
    known, unresolved = events.partition { |row| row['windowID'].is_a?(Integer) && row['windowID'] > 0 }
    duplicates = known.group_by { |row| [row['event'], row['windowID']] }.map do |(event, id), rows|
      { event: event, windowID: id, count: rows.length } if rows.length > 1
    end.compact
    { duplicateKnownEvents: duplicates,
      unresolvedIdentityEventCount: unresolved.length,
      identitiesComplete: unresolved.empty?,
      coverageComplete: unresolved.empty? && NAMES.all? do |name|
        known.select { |row| row['event'] == name }.map { |row| row['windowID'] }.sort == expected_ids.sort
      end }
  end
end
