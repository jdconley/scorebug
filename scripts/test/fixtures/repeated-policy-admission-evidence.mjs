import { repeatedReceiverIntervalFixture } from './repeated-receiver-interval-evidence.mjs';
import { withRepeatedAdmissionWitnesses } from './repeated-admission-witnesses.mjs';
import {
  repeatedMeasuredRecoveryFaultFixture,
  repeatedMeasuredDeliveryFaultFixture,
} from './repeated-measured-recovery-fault-evidence.mjs';

/** Synthetic raw admissions and owned faults sharing one publication identity.
 * This builds new test data; historical run exports are never changed. Full
 * source/processing/cadence replay must still supply its own raw evidence. */
export function repeatedAdmissionFaultFixture(routes) {
  const f = repeatedReceiverIntervalFixture();
  const publisher = 'dddddddd-dddd-4ddd-8ddd-000000000001';
  const reader = 'dddddddd-dddd-4ddd-8ddd-000000000002';
  const visited = new WeakSet();
  function useFaultPublication(value) {
    if (!value || typeof value !== 'object' || visited.has(value)) return;
    visited.add(value);
    for (const [key, child] of Object.entries(value)) {
      if (child === publisher) value[key] = reader;
      else if (child === reader) value[key] = publisher;
      else if (key === 'originPTS' && child === '0') value[key] = '9000';
      else useFaultPublication(child);
    }
  }
  useFaultPublication(f);
  const faults = repeatedMeasuredRecoveryFaultFixture(withRepeatedAdmissionWitnesses(f));
  return routes ? repeatedMeasuredDeliveryFaultFixture(routes, faults) : faults;
}
