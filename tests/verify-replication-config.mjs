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
function config(overlay, overrides = {}) {
  const args = ['compose', '--env-file', '.env.example', '--profile', '*', '-f', 'docker-compose.yml'];
  if (overlay) args.push('-f', 'docker-compose.replication.yml');
  args.push('config', '--format', 'json');
  return JSON.parse(execFileSync('docker', args, { cwd: root, env: { ...env, ...overrides }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
}
const base = config(false);
const merged = config(true, {
  PLAYER_REPLICATION_PASSWORD: '',
  SESSION_REPLICATION_PASSWORD: '',
  ANALYTICS_PLAYER_HA_DSN: '',
  ANALYTICS_SESSION_HA_DSN: '',
});
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
// Applicant and Credential: new PostgreSQL 18 primary volume, two standbys, multi-host JDBC URL through Spring.
for (const [pair, app] of [['applicant', 'applicant-service'], ['credential', 'credential-service']]) {
  const database = `${pair}-db`;
  const url = merged.services[app].environment.SPRING_DATASOURCE_URL;
  assert.ok(url.includes('targetServerType=primary'));
  assert.equal(merged.services[app].deploy.replicas, 2);
  assert.deepEqual(merged.services[app].depends_on, base.services[app].depends_on);
  for (const [key, value] of Object.entries(base.services[app].environment)) {
    assert.equal(merged.services[app].environment[key], value, `${app}.${key} changed`);
  }
  assert.equal(merged.services[database].image, 'postgres:18');
  assert.equal(merged.services[database].environment.NODE_MODE, 'primary');
  assert.ok(merged.services[database].volumes.some(v => v.source === `${pair}-db-primary` && v.target === '/var/lib/postgresql'));
  assert.ok(!merged.services[database].volumes.some(v => v.source === `${pair}-db-data`), 'the legacy PostgreSQL 16 volume must not be mounted');
  assert.ok(merged.services[database].command.includes('synchronous_standby_names='));
  assert.ok(url.includes(`${database}:5432`));
  for (const suffix of ['-standby-1', '-standby-2']) {
    const name = database + suffix;
    assert.equal(merged.services[name].image, 'postgres:18');
    assert.equal(merged.services[name].environment.NODE_MODE, 'standby');
    assert.equal(merged.services[name].environment.REPLICATION_UPSTREAM, database);
    assert.equal(merged.services[name].restart, 'no');
    assert.equal((merged.services[name].ports ?? []).length, 0);
    assert.ok(url.includes(name));
    assert.ok(merged.services[name].volumes.some(v => v.target === '/var/lib/postgresql' && v.source !== `${pair}-db-primary`));
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
  for (const [key, pair] of [['APPLICANT_DSN', 'applicant'], ['CREDENTIAL_DSN', 'credential']]) {
    // "primary": the read-only reader role would make libpq reject every node with "read-write"
    assert.ok(values[key].includes('target_session_attrs=primary'));
    for (const node of [`${pair}-db`, `${pair}-db-standby-1`, `${pair}-db-standby-2`]) assert.ok(values[key].includes(`${node}:5432`));
  }
  for (const [key, value] of Object.entries(base.services[service].environment)) {
    if (!['MODERATION_DSN', 'DISCORD_DSN', 'RULES_DSN', 'RECORD_DSN', 'PLAYER_DSN', 'SESSION_DSN', 'APPLICANT_DSN', 'CREDENTIAL_DSN'].includes(key)) assert.equal(values[key], value);
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
  const activeDsn = `postgresql://analytics_reader:fixture@${nodes.join(',')}/test?target_session_attrs=primary`;
  const active = config(true, { [`CPR_ANALYTICS_${dsn}`]: activeDsn });
  for (const job of ['analytics-scheduler', 'analytics-etl']) {
    const analytics = merged.services[job];
    assert.equal(analytics.environment[dsn], base.services[job].environment[dsn]);
    assert.equal(active.services[job].environment[dsn], activeDsn);
    const other = dsn === 'PLAYER_DSN' ? 'SESSION_DSN' : 'PLAYER_DSN';
    assert.equal(active.services[job].environment[other], base.services[job].environment[other]);
    assert.ok(Object.hasOwn(analytics.networks, `${pair}-replication`));
    assert.ok(!analytics.depends_on[legacyDb]);
  }
}
console.log('PASS: all eight replication clusters, app dependencies and ETL routing');
