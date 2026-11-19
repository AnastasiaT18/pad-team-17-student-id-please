import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
process.chdir(fileURLToPath(new URL('..', import.meta.url)));
const project = `pad17-repl-test-${randomBytes(4).toString('hex')}`;
const state = resolve('.replication', project);
mkdirSync(state, { recursive: true });
const envfile = `${state}/test.env`;
const basefile = `${state}/base.json`;
const password = randomBytes(24).toString('hex');
const readerPassword = randomBytes(24).toString('hex');
const images = {
  MODERATION_REPLICATION_APP_IMAGE: process.env.TEST_MODERATION_APP_IMAGE,
  MODERATION_DATABASE_IMAGE: process.env.TEST_MODERATION_DATABASE_IMAGE,
  DISCORD_DMS_REPLICATION_APP_IMAGE: process.env.TEST_DISCORD_APP_IMAGE,
  DISCORD_DMS_DATABASE_IMAGE: process.env.TEST_DISCORD_DATABASE_IMAGE,
};
for (const [name, value] of Object.entries(images)) assert.ok(value, `Supply the explicit test image for ${name}`);
const values = {
  ...images,
  MODERATION_DB_PASSWORD: password, DISCORD_DMS_DB_PASSWORD: password,
  MODERATION_REPLICATION_PASSWORD: randomBytes(24).toString('hex'), DISCORD_DMS_REPLICATION_PASSWORD: randomBytes(24).toString('hex'),
  ANALYTICS_WAREHOUSE_PASSWORD: password,
  ANALYTICS_WAREHOUSE_DSN: `postgresql://analytics:${password}@analytics-warehouse:5432/analytics`,
  ANALYTICS_MODERATION_REPLICATION_DSN: `postgresql://analytics_reader:${readerPassword}@moderation-db-router:5432/moderation`,
  ANALYTICS_DISCORD_REPLICATION_DSN: `postgresql://analytics_reader:${readerPassword}@discord-dms-db-router:5432/discord_dms`,
};
let example = readFileSync('.env.example', 'utf8');
for (const [key, value] of Object.entries(values)) example = example.replace(new RegExp(`^${key}=.*$`, 'm'), `${key}=${value}`);
writeFileSync(envfile, example, { mode: 0o600 });
const env = { ...process.env, CPR_PROJECT_NAME: project, CPR_ENV_FILE: envfile, CPR_COMPOSE_BASE_FILE: basefile, REPLICATION_STATE_ROOT: state, REPLICATION_SKIP_PULL: '1' };
function docker(args, input) {
  return execFileSync('docker', args, { env, input, encoding: 'utf8', timeout: 180000 }).trim();
}
const common = ['compose', '--env-file', envfile, '-p', project];
function base(...args) { return docker([...common, '-f', basefile, ...args]); }
function repl(...args) { return docker([...common, '-f', basefile, '-f', 'docker-compose.replication.yml', ...args]); }
function operation(script, ...args) { execFileSync('bash', [`scripts/${script}.sh`, ...args], { env, stdio: 'inherit', timeout: 600000 }); }
function sql(service, query, replicated = true) {
  const files = replicated ? ['-f', basefile, '-f', 'docker-compose.replication.yml'] : ['-f', basefile];
  return docker([...common, ...files, 'exec', '-T', service, 'sh', '-c', 'exec psql -XAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'], query);
}
async function eventually(check, description) {
  let error;
  for (let attempt = 0; attempt < 60; attempt++) {
    try { return await check(); } catch (caught) { error = caught; }
    await new Promise(done => setTimeout(done, 1000));
  }
  throw new Error(description, { cause: error });
}
let fixtureWritten = false;
try {
  const config = JSON.parse(docker([...common, '-f', 'docker-compose.yml', '--profile', '*', 'config', '--format', 'json']));
  // Only the rehearsal model changes names/ports; actual CPR resources stay untouched.
  for (const service of Object.values(config.services)) {
    delete service.container_name;
    delete service.ports;
  }
  for (const volume of Object.values(config.volumes)) { assert.ok(!volume.external); delete volume.name; }
  for (const network of Object.values(config.networks ?? {})) { assert.ok(!network.external); delete network.name; }
  for (const pair of ['moderation', 'discord-dms']) {
    const service = config.services[`${pair}-service`];
    service.ports = [{ target: 3000, published: '0', host_ip: '127.0.0.1' }];
    service.deploy = { replicas: 1 };
    service.environment.SERVICE_DISCOVERY_URL = '';
    if (pair === 'discord-dms') service.environment.REDIS_URL = '';
  }
  // The selective one-shot ETL below is real. Avoid running six unrelated sources in this fixture.
  config.services['analytics-scheduler'].entrypoint = ['python', '-c', 'import time; time.sleep(3600)'];
  writeFileSync(basefile, JSON.stringify(config), { mode: 0o600 });
  fixtureWritten = true;
  const merged = JSON.parse(repl('--profile', '*', 'config', '--format', 'json'));
  for (const pair of ['moderation', 'discord-dms']) {
    assert.equal(merged.services[`${pair}-service`].environment.DB_HOST, `${pair}-db-router`);
    assert.equal(merged.services[`${pair}-service`].environment.DB_SYNCHRONIZE, 'false');
    assert.deepEqual(merged.services[`${pair}-db`].profiles, ['legacy-databases']);
    assert.ok(!merged.services[`${pair}-service`].depends_on[`${pair}-db`]);
  }
  console.log(`Using disposable CPR project ${project}`);
  base('up', '-d', 'moderation-db', 'discord-dms-db', 'analytics-warehouse');
  for (const service of ['moderation-db', 'discord-dms-db', 'analytics-warehouse']) {
    await eventually(() => assert.equal(sql(service, 'SELECT 1', false), '1'), 'Fixture database did not start');
  }
  const channelId = randomUUID(), playerId = randomUUID(), sessionId = randomUUID(), decisionId = randomUUID();
  for (const [pair, readerScript] of [['moderation','moderation'],['discord-dms','discord']]) {
    repl('run','--rm','--no-deps','-e',`DB_HOST=${pair}-db`,`${pair}-db-migrate`);
    sql(`${pair}-db`, 'DROP TABLE migrations', false);
    const reader = readFileSync(`services/analytics/setup/${readerScript}-reader.sql`, 'utf8').replace('\\password analytics_reader', `ALTER ROLE analytics_reader PASSWORD '${readerPassword}';`);
    sql(`${pair}-db`, reader, false);
    sql(`${pair}-db`, 'CREATE ROLE reader_group NOLOGIN; GRANT reader_group TO analytics_reader WITH INHERIT FALSE, SET TRUE;', false);
  }
  sql('moderation-db', `INSERT INTO decisions(id,session_id,applicant_id,moderator_id,verdict) VALUES ('${decisionId}','${sessionId}','${randomUUID()}','${playerId}','accept'); INSERT INTO decision_violations(decision_id,rule_id) VALUES ('${decisionId}','fixture-rule'); INSERT INTO decision_outbox(decision_id,payload) VALUES ('${decisionId}','{}');`, false);
  sql('discord-dms-db', `INSERT INTO channels(id,session_id,name) VALUES ('${channelId}','${sessionId}','fixture'); INSERT INTO channel_members(channel_id,player_id) VALUES ('${channelId}','${playerId}'); INSERT INTO messages(channel_id,sender_id,content) VALUES ('${channelId}','${playerId}','private fixture content');`, false);
  repl('run', '--rm', '--no-deps', 'analytics-migrate');
  operation('replication-cutover','backup');
  const backup = readFileSync(`${state}/backup`, 'utf8').trim();
  const premature = spawnSync('bash',['scripts/replication-cutover.sh','activate'],{env,encoding:'utf8'});
  assert.notEqual(premature.status,0);
  assert.match(premature.stderr,/Run verify successfully/);
  if (process.env.TEST_ROLLBACK_ONLY === '1') {
    operation('replication-cutover','rollback-before-activation');
    for (const pair of ['moderation','discord-dms']) {
      await eventually(() => assert.equal(sql(`${pair}-db`, 'SELECT 1', false),'1'),'Original database did not restart');
    }
    const stale = spawnSync('bash',['scripts/replication-cutover.sh','restore',backup],{env,encoding:'utf8'});
    assert.notEqual(stale.status,0);
    assert.match(stale.stderr,/cutover was rolled back/);
    console.log('PASS: rollback before activation preserves original databases and blocks reuse of stale snapshots');
  } else {
  operation('replication-cutover','restore',backup);
  for (const pair of ['moderation','discord-dms']) {
    const options = sql(`${pair}-db-1`, "SELECT m.inherit_option,m.set_option FROM pg_auth_members m JOIN pg_roles p ON p.oid=m.roleid JOIN pg_roles c ON c.oid=m.member WHERE p.rolname='reader_group' AND c.rolname='analytics_reader'");
    assert.equal(options, 'f|t');
  }
  operation('replication-cutover','verify');
  assert.equal(sql('analytics-warehouse','SELECT count(*) FROM analytics.fact_decisions'), '1');
  assert.equal(sql('analytics-warehouse','SELECT count(*) FROM analytics.fact_messages'), '1');
  const permissionsCode = "import os,psycopg; c=psycopg.connect(os.environ['DISCORD_DSN']); r=c.execute(\"SELECT has_column_privilege(current_user,'public.messages','content','SELECT'),has_table_privilege(current_user,'public.messages','INSERT')\").fetchone(); assert r==(False,False),r; print('PASS: preserved column restrictions and read-only ETL access')";
  repl('run','--rm','--no-deps','--entrypoint','python','analytics-etl','-c',permissionsCode);
  operation('replication-cutover','activate');
  const appIds = {};
  const starts = {};
  const urls = {};
  for (const pair of ['moderation','discord-dms']) {
    appIds[pair] = repl('ps','-q',`${pair}-service`);
    starts[pair] = docker(['inspect','-f','{{.State.StartedAt}}',appIds[pair]]);
    urls[pair] = `http://127.0.0.1:${repl('port',`${pair}-service`,'3000').split(':').at(-1)}`;
    await eventually(async () => assert.equal((await fetch(`${urls[pair]}/health`)).status,200),'Application did not start');
    const old = repl('ps','-q',`${pair}-db-1`);
    docker(['kill',old]);
    operation('database-replication',pair,'failover','db-2');
    docker(['start',old]);
    await eventually(() => assert.equal(docker(['inspect','-f','{{.State.Running}}',old]),'false'),'Fenced CPR node restarted');
    await eventually(async () => assert.equal((await fetch(`${urls[pair]}/health`)).status,200),'Application failed to reconnect');
    assert.equal(docker(['inspect','-f','{{.State.StartedAt}}',appIds[pair]]),starts[pair]);
  }
  const response = await fetch(`${urls['discord-dms']}/channels/${channelId}/messages`, {method:'POST',headers:{'content-type':'application/json','x-player-id':playerId},body:JSON.stringify({sender_id:playerId,content:'message after promotion'})});
  assert.equal(response.status,201,await response.text());
  assert.equal((await fetch(`${urls.moderation}/decisions/${decisionId}`)).status,200);
  sql('moderation-db-2',`INSERT INTO decisions(session_id,applicant_id,moderator_id,verdict) VALUES ('${sessionId}','${randomUUID()}','${playerId}','reject')`);
  repl('run','--rm','--no-deps','analytics-etl','--mode','reconcile','--source','moderation-service','--source','discord-dms-service');
  assert.equal(sql('analytics-warehouse','SELECT count(*) FROM analytics.fact_decisions'),'2');
  assert.equal(sql('analytics-warehouse','SELECT count(*) FROM analytics.fact_messages'),'2');
  for (const pair of ['moderation','discord-dms']) {
    operation('database-replication',pair,'rejoin','db-1','--rebuild');
    operation('database-replication',pair,'rejoin','db-3','--rebuild');
    operation('database-replication',pair,'verify');
  }
  const rollback = spawnSync('bash',['scripts/replication-cutover.sh','rollback-before-activation'],{env,encoding:'utf8'});
  assert.notEqual(rollback.status,0);
  assert.match(rollback.stderr,/Writes may exist/);
  for (const pair of ['moderation','discord-dms']) {
    const old = base('ps','-a','-q',`${pair}-db`);
    assert.equal(docker(['inspect','-f','{{.State.Running}}',old]),'false');
    assert.equal(docker(['volume','ls','-q','--filter',`label=com.docker.compose.project=${project}`,'--filter',`label=com.docker.compose.volume=${pair}-db-data`]).split('\n').filter(Boolean).length,1);
  }
  console.log('PASS: CPR overlay, backup/restore, exact records, roles and restricted readers, versioned migrations, application reconnection, ETL through promoted primaries, fencing, both standby rebuilds, retained original volumes and unsafe rollback rejection');
  }
} finally {
  if (fixtureWritten) {
    const cleanup = spawnSync('docker',[...common,'-f',basefile,'-f','docker-compose.replication.yml','--profile','legacy-databases','down','--volumes','--remove-orphans'],{env,stdio:'inherit',timeout:120000});
    if(cleanup.status===0) {
      rmSync(state,{recursive:true,force:true});
      rmSync(resolve('.replication-backups',project),{recursive:true,force:true});
    } else console.error(`Inspect remaining disposable project ${project}`);
  }
}
