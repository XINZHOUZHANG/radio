#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HTTP_METHODS = ['get', 'post', 'put', 'patch', 'delete'];

function lineNumberAt(source, index) {
  return source.slice(0, index).split('\n').length;
}

function normalizePath(prefix, routePath) {
  const left = prefix === '/' ? '' : prefix.replace(/\/$/, '');
  const right = routePath === '/' ? '' : routePath.replace(/^\//, '');
  if (!right) return left || '/';
  const joined = `${left}/${right}`.replace(/\/+/g, '/');
  return joined || '/';
}

function readText(path) {
  return readFileSync(path, 'utf8').replace(/\r\n/g, '\n');
}

function parseRoleScopes(serverSource) {
  const roleByRegistration = new Map();
  const scopePattern = /registerRoleScope\(fastify,\s*UserRole\.(ADMIN|OPERATOR|VIEWER),\s*async\s*\(scope\)\s*=>\s*\{/g;
  let scopeMatch;

  while ((scopeMatch = scopePattern.exec(serverSource)) !== null) {
    let depth = 1;
    let cursor = scopePattern.lastIndex;
    while (cursor < serverSource.length && depth > 0) {
      if (serverSource[cursor] === '{') depth += 1;
      if (serverSource[cursor] === '}') depth -= 1;
      cursor += 1;
    }
    const block = serverSource.slice(scopePattern.lastIndex, cursor - 1);
    const registrationPattern = /scope\.register\(\s*([A-Za-z_$][\w$]*)\s*,\s*\{[\s\S]*?prefix:\s*['"]([^'"]+)['"]/g;
    let registrationMatch;
    while ((registrationMatch = registrationPattern.exec(block)) !== null) {
      roleByRegistration.set(registrationMatch[1], scopeMatch[1].toLowerCase());
    }
  }

  return roleByRegistration;
}

export function parseRegistrations(serverSource) {
  const registrations = new Map();
  const pattern = /(?:fastify|scope)\.register\(\s*([A-Za-z_$][\w$]*)\s*,\s*\{[^{}]*?prefix:\s*['"]([^'"]+)['"]/g;
  let match;
  while ((match = pattern.exec(serverSource)) !== null) {
    registrations.set(match[1], match[2]);
  }
  return registrations;
}

export function findRegisteredRouteName(source, registrations) {
  for (const name of registrations.keys()) {
    const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const declaration = new RegExp(
      `\\bexport\\s+(?:async\\s+function\\s+${escapedName}\\b|const\\s+${escapedName}\\s*=)`,
    );
    if (declaration.test(source)) return name;
  }
  return undefined;
}

function authorizationHints(source, startIndex, endIndex, scopeMinimumRole) {
  const header = source.slice(startIndex, Math.min(endIndex, startIndex + 1600));
  const roles = [...header.matchAll(/requireRole\(UserRole\.(ADMIN|OPERATOR|VIEWER)\)/g)]
    .map((match) => match[1].toLowerCase());
  const abilities = [...header.matchAll(/requireAbility(?:For)?\(\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]/g)]
    .map((match) => `${match[1]}:${match[2]}`);

  let minimumRole = roles[0] ?? scopeMinimumRole ?? 'route-specific';
  if (/\badminOnly\b/.test(header)) minimumRole = 'admin';

  return {
    minimumRole,
    abilities: [...new Set(abilities)],
  };
}

export function extractFastifyRoutes(source, options = {}) {
  const prefix = options.prefix ?? '';
  const scopeMinimumRole = options.scopeMinimumRole ?? null;
  const sourceFile = options.sourceFile ?? 'unknown';
  const matches = [];
  const routePattern = new RegExp(
    `\\bfastify\\.(${HTTP_METHODS.join('|')})\\b[\\s\\S]{0,900}?\\(\\s*(['\"])([^'\"\\r\\n]+)\\2`,
    'g',
  );
  let match;
  while ((match = routePattern.exec(source)) !== null) {
    matches.push({
      index: match.index,
      method: match[1].toUpperCase(),
      routePath: match[3],
    });
  }

  const objectRoutePattern = /\bfastify\.route\(\s*\{[\s\S]{0,1000}?method:\s*(\[[^\]]+\]|['"][^'"]+['"])[\s\S]{0,1000}?url:\s*['"]([^'"]+)['"]/g;
  while ((match = objectRoutePattern.exec(source)) !== null) {
    const methods = [...match[1].matchAll(/['"]([A-Za-z]+)['"]/g)].map((item) => item[1].toUpperCase());
    for (const method of methods) {
      matches.push({ index: match.index, method, routePath: match[2] });
    }
  }

  matches.sort((a, b) => a.index - b.index || a.method.localeCompare(b.method));
  return matches.map((item, index) => {
    const nextIndex = matches[index + 1]?.index ?? source.length;
    const auth = authorizationHints(source, item.index, nextIndex, scopeMinimumRole);
    const fullPath = normalizePath(prefix, item.routePath);
    return {
      method: item.method,
      path: fullPath,
      source: sourceFile,
      line: lineNumberAt(source, item.index),
      minimumRole: fullPath.includes('/internal/') ? 'internal-service-token' : auth.minimumRole,
      abilities: auth.abilities,
    };
  });
}

function extractWebSocketTypes(contractSource, commandSource, eventSource) {
  const enumBlock = contractSource.match(/export enum WSMessageType\s*\{([\s\S]*?)\n\}/)?.[1] ?? '';
  const values = new Map();
  for (const match of enumBlock.matchAll(/^\s*([A-Z0-9_]+)\s*=\s*['"]([^'"]+)['"]/gm)) {
    values.set(match[1], match[2]);
  }

  const commands = new Set(
    [...commandSource.matchAll(/\[WSMessageType\.([A-Z0-9_]+)\]\s*:/g)].map((match) => match[1]),
  );
  const events = new Set(
    [...eventSource.matchAll(/\[WSMessageType\.([A-Z0-9_]+)\]\s*:/g)].map((match) => match[1]),
  );

  return [...values.entries()].map(([name, value]) => ({
    name,
    value,
    direction: commands.has(name) && events.has(name)
      ? 'bidirectional'
      : commands.has(name)
        ? 'client-to-server'
        : events.has(name)
          ? 'server-to-client'
          : 'server-or-specialized-channel',
  }));
}

function readUpstreamCommit(upstreamRoot) {
  try {
    return execFileSync(
      'git',
      ['-c', `safe.directory=${upstreamRoot.replaceAll('\\', '/')}`, '-C', upstreamRoot, 'rev-parse', 'HEAD'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
    ).trim();
  } catch {
    return 'unknown';
  }
}

export function extractContract(upstreamRoot) {
  const root = resolve(upstreamRoot);
  const serverRoot = join(root, 'packages', 'server', 'src');
  const serverPath = join(serverRoot, 'server.ts');
  const routeRoot = join(serverRoot, 'routes');
  const contractPath = join(root, 'packages', 'contracts', 'src', 'schema', 'websocket.schema.ts');
  const wsServerPath = join(serverRoot, 'websocket', 'WSServer.ts');
  const wsClientHandlerPath = join(root, 'packages', 'core', 'src', 'websocket', 'WSMessageHandler.ts');

  for (const required of [serverPath, routeRoot, contractPath, wsServerPath, wsClientHandlerPath]) {
    if (!existsSync(required)) throw new Error(`TX-5DR source file is missing: ${required}`);
  }

  const serverSource = readText(serverPath);
  const registrations = parseRegistrations(serverSource);
  const roleScopes = parseRoleScopes(serverSource);
  const routes = extractFastifyRoutes(serverSource, {
    sourceFile: relative(root, serverPath).replaceAll('\\', '/'),
  });

  const routeFiles = readdirSync(routeRoot).filter((name) => name.endsWith('.ts') && !name.includes('.test.'));
  for (const fileName of routeFiles) {
    const path = join(routeRoot, fileName);
    const source = readText(path);
    const registrationName = findRegisteredRouteName(source, registrations);
    const prefix = registrationName ? registrations.get(registrationName) : undefined;
    if (!prefix) continue;
    routes.push(...extractFastifyRoutes(source, {
      prefix,
      scopeMinimumRole: roleScopes.get(registrationName) ?? null,
      sourceFile: relative(root, path).replaceAll('\\', '/'),
    }));
  }

  const deviceUiPath = join(serverRoot, 'device-ui', 'routes.ts');
  if (existsSync(deviceUiPath)) {
    const source = readText(deviceUiPath);
    routes.push(...extractFastifyRoutes(source, {
      prefix: registrations.get('deviceUiRoutes') ?? '/api/device-ui',
      sourceFile: relative(root, deviceUiPath).replaceAll('\\', '/'),
      scopeMinimumRole: 'device-service-token',
    }));
  }

  const dedupedRoutes = [...new Map(
    routes.map((route) => [`${route.method} ${route.path}`, route]),
  ).values()].sort((a, b) => a.path.localeCompare(b.path) || a.method.localeCompare(b.method));

  return {
    schemaVersion: 1,
    upstream: {
      repository: 'https://github.com/boybook/tx-5dr',
      commit: readUpstreamCommit(root),
      conservativeLicense: 'GPL-3.0',
    },
    http: {
      basePath: '/api',
      routes: dedupedRoutes,
    },
    websocket: {
      controlPath: '/api/ws',
      logbookPath: '/api/ws/logbook',
      messages: extractWebSocketTypes(
        readText(contractPath),
        readText(wsServerPath),
        readText(wsClientHandlerPath),
      ),
    },
    realtimeAudio: {
      sessionPath: '/api/realtime/session',
      compatibilityPath: '/api/realtime/ws-compat',
      rtcDataAudioPath: '/api/realtime/rtc-data-audio',
      compatibilityFrameMagic: ['TX5D', 'TX5E'],
      supportedDirections: ['recv', 'send'],
      supportedScopes: ['radio', 'openwebrx-preview'],
    },
  };
}

function runCli() {
  const upstreamRoot = process.argv[2];
  const outputPath = process.argv[3];
  if (!upstreamRoot || !outputPath) {
    throw new Error('Usage: node scripts/extract-tx5dr-contract.mjs <tx5dr-root> <output-json>');
  }
  const contract = extractContract(upstreamRoot);
  const target = resolve(outputPath);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, `${JSON.stringify(contract, null, 2)}\n`, 'utf8');
  process.stdout.write(`Wrote ${contract.http.routes.length} HTTP routes and ${contract.websocket.messages.length} WebSocket message types to ${target}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli();
}
