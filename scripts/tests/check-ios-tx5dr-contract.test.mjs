import assert from 'node:assert/strict';
import test from 'node:test';
import {
  apiPathForClientPath,
  clientPathMatchesRoute,
  extractHTTPUsages,
  extractInboundMessageTypes,
  extractOutboundMessageTypes,
  extractSettingsEndpointUsages,
} from '../check-ios-tx5dr-contract.mjs';

test('extracts multiline typed REST calls from Swift', () => {
  const source = `
    try await request(.get, "/auth/me")
    let response: Value = try await request(
      .delete,
      "/logbooks/\\(logbookId)/qsos/\\(qsoId)"
    )
  `;
  assert.deepEqual(extractHTTPUsages(source), [
    { method: 'GET', path: '/auth/me' },
    { method: 'DELETE', path: '/logbooks/\\(logbookId)/qsos/\\(qsoId)' },
  ]);
});

test('matches Swift interpolated path segments to contract parameters', () => {
  assert.equal(apiPathForClientPath('/operators'), '/api/operators');
  assert(clientPathMatchesRoute('/auth/tokens/\\(id)', '/api/auth/tokens/:id'));
  assert(clientPathMatchesRoute('/logbooks/\\(book)/qsos/\\(qso)', '/api/logbooks/:id/qsos/:qsoId'));
  assert(!clientPathMatchesRoute('/radio/\\(id)', '/api/radio/capabilities/:id'));
  assert(!clientPathMatchesRoute('/auth/tokens/\\(id)/extra', '/api/auth/tokens/:id'));
});

test('extracts outbound and inbound WebSocket message names', () => {
  const source = `
    func command() { send("startEngine") }
    private func handle(_ envelope: Envelope) {
      switch envelope.type {
      case "systemStatus", "clockStatusChanged": break
      case "error": break
      default: break
      }
    }
    private func mergeFrames() {}
  `;
  assert.deepEqual(extractOutboundMessageTypes(source), ['startEngine']);
  assert.deepEqual(extractInboundMessageTypes(source), [
    'systemStatus',
    'clockStatusChanged',
    'error',
  ]);
});

test('extracts read and write methods from the advanced settings registry', () => {
  const source = `
    .init(title: "Audio", subtitle: "", loadPath: "/audio/settings", savePath: "/audio/settings", saveMethod: .post, adminOnly: true),
    .init(title: "Status", subtitle: "", loadPath: "/radio/status", savePath: nil, saveMethod: .get, adminOnly: false),
  `;
  assert.deepEqual(extractSettingsEndpointUsages(source), [
    { method: 'GET', path: '/audio/settings' },
    { method: 'POST', path: '/audio/settings' },
    { method: 'GET', path: '/radio/status' },
  ]);
});
