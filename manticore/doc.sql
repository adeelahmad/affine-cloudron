CREATE TABLE IF NOT EXISTS doc (
  workspace_id string attribute,
  doc_id string attribute,
  title text,
  summary string stored,
  journal string stored,
  created_by_user_id string attribute,
  updated_by_user_id string attribute,
  created_at timestamp,
  updated_at timestamp
)
charset_table = 'non_cjk, cjk'
index_field_lengths = '1';
