DELETE FROM ops.feature_flags WHERE key IN ('legal.acceptance.required', 'app.force_update');
DROP TABLE IF EXISTS auth.legal_acceptances;
DROP TABLE IF EXISTS ops.legal_documents;
