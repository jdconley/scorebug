// Test-only wire constructor; Swift is the production writer. Exact cross-language
// decoding is additionally exercised against a retained real diagnostic export.
export function dictionaryQualityFixture(inline) {
  const quality = structuredClone(inline),
    tables = { thermal: [], transport: [], queue: [] };
  const indexes = Object.fromEntries(Object.keys(tables).map((k) => [k, new Map()]));
  for (const row of quality.events)
    if (row.evidence)
      for (const kind of Object.keys(tables)) {
        const history = row.evidence[kind];
        if (history === null && kind === 'queue') continue;
        const field = kind === 'queue' ? 'states' : 'samples',
          rangeKey = kind === 'queue' ? 'stateRanges' : 'sampleRanges',
          countKey = kind === 'queue' ? 'stateCount' : 'sampleCount';
        const values = history[field],
          ranges = [];
        for (const entry of values) {
          const key = JSON.stringify(
            Object.fromEntries(
              Object.keys(entry)
                .sort()
                .map((k) => [k, entry[k]]),
            ),
          );
          if (!indexes[kind].has(key)) {
            indexes[kind].set(key, tables[kind].length);
            tables[kind].push(entry);
          }
          const index = indexes[kind].get(key),
            last = ranges.at(-1);
          if (last && last[0] + last[1] === index) last[1]++;
          else ranges.push([index, 1]);
        }
        history[countKey] = values.length;
        history[rangeKey] = ranges;
        delete history[field];
      }
  quality.formatVersion = 6;
  quality.evidenceDictionary = { formatVersion: 1, ...tables };
  return quality;
}
