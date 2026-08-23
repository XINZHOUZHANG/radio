import assert from 'node:assert/strict';
import test from 'node:test';
import {
  extractFastifyRoutes,
  findRegisteredRouteName,
  parseRegistrations,
} from '../extract-tx5dr-contract.mjs';

test('extracts single-line and generic Fastify routes with their full prefix', () => {
  const source = `
    fastify.get('/status', async () => ({}));
    fastify.post<{ Params: { id: string }; Body: unknown }>(
      '/tokens/:id/regenerate',
      { preHandler: [requireRole(UserRole.ADMIN)] },
      async () => ({}),
    );
  `;

  assert.deepEqual(extractFastifyRoutes(source, {
    prefix: '/api/auth',
    sourceFile: 'routes/auth.ts',
  }), [
    {
      method: 'GET',
      path: '/api/auth/status',
      source: 'routes/auth.ts',
      line: 2,
      minimumRole: 'route-specific',
      abilities: [],
    },
    {
      method: 'POST',
      path: '/api/auth/tokens/:id/regenerate',
      source: 'routes/auth.ts',
      line: 3,
      minimumRole: 'admin',
      abilities: [],
    },
  ]);
});

test('extracts object routes and ability hints', () => {
  const source = `
    fastify.route({ method: ['GET', 'HEAD'], url: '/', handler: async () => ({}) });
    fastify.post('/frequency', {
      preHandler: [requireAbilityFor('execute', 'RadioFrequency', () => ({}))],
    }, async () => ({}));
  `;

  const routes = extractFastifyRoutes(source, {
    prefix: '/api/radio',
    scopeMinimumRole: 'viewer',
    sourceFile: 'routes/radio.ts',
  });

  assert.deepEqual(routes.map(({ method, path }) => ({ method, path })), [
    { method: 'GET', path: '/api/radio' },
    { method: 'HEAD', path: '/api/radio' },
    { method: 'POST', path: '/api/radio/frequency' },
  ]);
  assert.deepEqual(routes.at(-1).abilities, ['execute:RadioFrequency']);
  assert.equal(routes.at(-1).minimumRole, 'viewer');
});

test('does not associate an optionless registration with a later prefix', () => {
  const registrations = parseRegistrations(`
    await fastify.register(optionlessRoutes);
    await fastify.register(authRoutes, { prefix: '/api/auth' });
  `);

  assert.deepEqual([...registrations], [['authRoutes', '/api/auth']]);
});

test('finds the registered route export after earlier exported helpers', () => {
  const registrations = new Map([
    ['operatorRoutes', '/api/operators'],
    ['radioRoutes', '/api/radio'],
  ]);
  const source = `
    export async function runTemporaryPhysicalPttTest() {}
    export async function radioRoutes(fastify: FastifyInstance) {}
  `;

  assert.equal(findRegisteredRouteName(source, registrations), 'radioRoutes');
});
