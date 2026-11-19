-- Export replayable role definitions, password hashes, memberships and DB settings.
-- Execute only against the source with psql -XAt; the resulting file is private.
SELECT format('SELECT %L WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname=%L) \gexec',
              format('CREATE ROLE %I',rolname),rolname)
FROM pg_authid WHERE rolname !~ '^pg_' AND rolname <> 'replicator' ORDER BY rolname;
SELECT format('ALTER ROLE %I WITH %s %s %s %s %s %s %s CONNECTION LIMIT %s PASSWORD %L VALID UNTIL %L;',
  rolname, CASE WHEN rolsuper THEN 'SUPERUSER' ELSE 'NOSUPERUSER' END,
  CASE WHEN rolinherit THEN 'INHERIT' ELSE 'NOINHERIT' END,
  CASE WHEN rolcreaterole THEN 'CREATEROLE' ELSE 'NOCREATEROLE' END,
  CASE WHEN rolcreatedb THEN 'CREATEDB' ELSE 'NOCREATEDB' END,
  CASE WHEN rolcanlogin THEN 'LOGIN' ELSE 'NOLOGIN' END,
  CASE WHEN rolreplication THEN 'REPLICATION' ELSE 'NOREPLICATION' END,
  CASE WHEN rolbypassrls THEN 'BYPASSRLS' ELSE 'NOBYPASSRLS' END,
  rolconnlimit,rolpassword,COALESCE(rolvaliduntil::text,'infinity'))
FROM pg_authid WHERE rolname !~ '^pg_' AND rolname <> 'replicator' ORDER BY rolname;
SELECT format('GRANT %I TO %I WITH ADMIN %s, INHERIT %s, SET %s;',
  parent.rolname,child.rolname,CASE WHEN m.admin_option THEN 'true' ELSE 'false' END,CASE WHEN m.inherit_option THEN 'true' ELSE 'false' END,CASE WHEN m.set_option THEN 'true' ELSE 'false' END)
FROM pg_auth_members m JOIN pg_roles parent ON parent.oid=m.roleid JOIN pg_roles child ON child.oid=m.member
WHERE child.rolname !~ '^pg_' AND child.rolname <> 'replicator';
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC;',current_database());
SELECT format('GRANT %s ON DATABASE %I TO %s%s;', a.privilege_type,d.datname,
  CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END,
  CASE WHEN a.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END)
FROM pg_database d CROSS JOIN LATERAL aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) a
WHERE d.datname=current_database();
SELECT format('ALTER %s SET %I TO %L;',
  CASE WHEN s.setrole=0 THEN format('DATABASE %I',current_database())
       ELSE format('ROLE %I%s',pg_get_userbyid(s.setrole),CASE WHEN s.setdatabase=0 THEN '' ELSE format(' IN DATABASE %I',current_database()) END) END,
  split_part(setting,'=',1),substr(setting,strpos(setting,'=')+1))
FROM pg_db_role_setting s CROSS JOIN LATERAL unnest(s.setconfig) setting
WHERE (s.setdatabase=0 OR s.setdatabase=(SELECT oid FROM pg_database WHERE datname=current_database()))
  AND (s.setrole=0 OR pg_get_userbyid(s.setrole) <> 'replicator');
