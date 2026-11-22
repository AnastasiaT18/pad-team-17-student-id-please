// Configuration-only regression: never contacts Docker Engine, pulls images or starts containers.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const env = {
  ...process.env,
  MODERATION_REPLICATION_APP_IMAGE: 'config-validation/moderation:local',
  MODERATION_DATABASE_IMAGE: 'config-validation/moderation-postgres:local',
  DISCORD_DMS_REPLICATION_APP_IMAGE: 'config-validation/discord:local',
  DISCORD_DMS_DATABASE_IMAGE: 'config-validation/discord-postgres:local',
  REPLICATION_STATE_ROOT: resolve(tmpdir(), 'pad17-config-validation'),
};
function config(overlay) {
  const args = ['compose', '--env-file', '.env.example', '--profile', '*', '-f', 'docker-compose.yml'];
  if (overlay) args.push('-f', 'docker-compose.replication.yml');
  args.push('config', '--format', 'json');
  return JSON.parse(execFileSync('docker', args, { cwd: root, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
}
const base = config(false);
const merged = config(true);
for (const [database, app, volume] of [
  ['server-rules-db', 'server-rules-service', 'server-rules-db-data'],
  ['university-record-db', 'university-record-service', 'university-record-db-data'],
]) {
  assert.equal(merged.services[app].deploy.replicas, 2);
  for (const [key, value] of Object.entries(base.services[app].environment)) {
    if (key !== 'DB_URL') assert.equal(merged.services[app].environment[key], value, `${app}.${key} changed`);
  }
  const url = merged.services[app].environment.DB_URL;
  assert.ok(url.includes('targetServerType=primary'));
  assert.deepEqual(merged.services[app].depends_on, base.services[app].depends_on);
  assert.equal(merged.volumes[volume].name, base.volumes[volume].name);
  assert.ok(merged.services[database].volumes.some(v => v.source === volume && v.target === '/var/lib/postgresql'));
  assert.ok(merged.services[database].command.includes('synchronous_standby_names='));
  for (const suffix of ['-standby-1', '-standby-2']) {
    const name = database + suffix;
    assert.equal(merged.services[name].environment.NODE_MODE, 'standby');
    assert.equal(merged.services[name].environment.REPLICATION_UPSTREAM, database);
    assert.equal(merged.services[name].restart, 'no');
    assert.equal((merged.services[name].ports ?? []).length, 0);
    assert.ok(url.includes(name));
  }
}
for (const pair of ['moderation', 'discord-dms']) {
  assert.deepEqual(merged.services[`${pair}-db`].profiles, ['legacy-databases']);
  assert.equal(merged.services[`${pair}-service`].environment.DB_HOST, `${pair}-db-router`);
  assert.equal(merged.services[`${pair}-service`].environment.DB_SYNCHRONIZE, 'false');
  assert.ok(!merged.services[`${pair}-service`].depends_on[`${pair}-db`]);
  assert.equal(merged.networks[`${pair}-replication`].internal, true);
  for (const n of [1, 2, 3]) assert.ok(merged.services[`${pair}-db-${n}`]);
}
for (const service of ['analytics-scheduler', 'analytics-etl']) {
  const values = merged.services[service].environment;
  assert.ok(values.MODERATION_DSN.includes('moderation-db-router'));
  assert.ok(values.DISCORD_DSN.includes('discord-dms-db-router'));
  for (const key of ['RULES_DSN', 'RECORD_DSN']) assert.ok(values[key].includes('target_session_attrs=read-write'));
  for (const [key, value] of Object.entries(base.services[service].environment)) {
    if (!['MODERATION_DSN', 'DISCORD_DSN', 'RULES_DSN', 'RECORD_DSN', 'PLAYER_DSN', 'SESSION_DSN'].includes(key)) assert.equal(values[key], value);
  }
  assert.ok(merged.services[service].depends_on['moderation-db-router']);
  assert.ok(merged.services[service].depends_on['discord-dms-db-router']);
  assert.ok(!merged.services[service].depends_on['moderation-db']);
  assert.ok(!merged.services[service].depends_on['discord-dms-db']);
}
const playerSessionClusters = [
  ['player', 'player-service', 'player-db', 'PLAYER_DSN'],
  ['session', 'server-moderation-session-service', 'server-moderation-session-db', 'SESSION_DSN'],
];
for (const [pair, app, legacyDb, dsn] of playerSessionClusters) {
  const nodes = [1, 2, 3].map(n => `${pair}-db-${n}`);
  const appService = merged.services[app];
  assert.deepEqual(merged.services[legacyDb].profiles, ['legacy-databases']);
  assert.equal(appService.environment.DB_HOSTS, nodes.join(','));
  assert.equal(appService.environment.DB_HOST, undefined);
  assert.equal(appService.deploy.replicas, base.services[app].deploy.replicas);
  assert.ok(!appService.depends_on[legacyDb]);
  assert.equal(merged.networks[`${pair}-replication`].internal, true);
  assert.ok(Object.hasOwn(appService.networks, `${pair}-replication`));
  for (const [index, node] of nodes.entries()) {
    const database = merged.services[node];
    assert.equal(database.image, 'janetag/pad-postgres-replication:17-lab5.1');
    assert.equal(database.environment.NODE_NAME, `db-${index + 1}`);
    assert.deepEqual(database.profiles, ['player-session-replication-nodes']);
    assert.equal(database.volumes[0].source, `${pair}-replica-${index + 1}`);
  }
  for (const job of ['analytics-scheduler', 'analytics-etl']) {
    const analytics = merged.services[job];
    assert.ok(analytics.environment[dsn].includes('target_session_attrs=primary'));
    for (const node of nodes) assert.ok(analytics.environment[dsn].includes(node));
    assert.ok(Object.hasOwn(analytics.networks, `${pair}-replication`));
    assert.ok(!analytics.depends_on[legacyDb]);
  }
}
console.log('PASS: all six replication clusters, app dependencies and ETL routing');
