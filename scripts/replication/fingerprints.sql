-- Exact row comparisons for lab-sized databases; no row values leave PostgreSQL.
SELECT format('SELECT %L || ''|'' || count(*) || ''|'' || md5(COALESCE(string_agg(to_jsonb(t)::text, chr(10) ORDER BY to_jsonb(t)::text), '''')) FROM %I.%I t;',
  tablename,schemaname,tablename)
FROM pg_tables WHERE schemaname='public' ORDER BY tablename
\gexec
