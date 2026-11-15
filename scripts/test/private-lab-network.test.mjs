import test from 'node:test';
import assert from 'node:assert/strict';
import { isPrivateLabIPv4, validatePrivateLabBind } from '../private-lab-network.mjs';

const assigned = (host, extra = {}) => ({
  en0: [{ address: host, family: 'IPv4', internal: false, ...extra }],
});
test('bind validation accepts only exact loopback or assigned canonical RFC1918 interfaces', () => {
  assert.equal(validatePrivateLabBind('127.0.0.1', {}), '127.0.0.1');
  for (const host of ['10.0.0.2', '172.16.0.2', '172.31.255.254', '192.168.1.130']) {
    assert.equal(isPrivateLabIPv4(host), true);
    assert.equal(validatePrivateLabBind(host, assigned(host)), host);
    assert.throws(() => validatePrivateLabBind(host, {}), /assigned/);
    assert.throws(
      () => validatePrivateLabBind(host, assigned(host, { internal: true })),
      /assigned/,
    );
  }
});
test('wildcard public DNS IPv6 unassigned and noncanonical addresses cannot bind or become LAN peers', () => {
  for (const host of [
    '0.0.0.0',
    '127.0.0.2',
    '8.8.8.8',
    '172.15.1.1',
    '172.32.0.1',
    '169.254.1.1',
    'localhost',
    '192.168.1.013',
    '010.0.0.1',
    ' 10.0.0.1',
    '10.0.0.1\n',
    '10.0.0.1:12',
    '::1',
    '::ffff:192.168.1.130',
    '192.168.1.256',
    '0xc0a80182',
    '',
    null,
    undefined,
    123,
    {},
    [],
  ]) {
    assert.equal(isPrivateLabIPv4(host), false, String(host));
    assert.throws(() => validatePrivateLabBind(host, assigned(host)), /bind/, String(host));
  }
  assert.equal(isPrivateLabIPv4('127.0.0.1'), false, 'Loopback is never a physical LAN sender');
});
