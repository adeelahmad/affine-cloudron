CREATE TABLE IF NOT EXISTS block (
  workspace_id string attribute,
  doc_id string attribute,
  block_id string attribute,
  content text,
  flavour string attribute,
  flavour_indexed string attribute indexed,
  blob string attribute indexed,
  ref_doc_id string attribute indexed,
  ref string stored,
  parent_flavour string attribute,
  parent_flavour_indexed string attribute indexed,
  parent_block_id string attribute,
  parent_block_id_indexed string attribute indexed,
  additional string stored,
  markdown_preview string stored,
  created_by_user_id string attribute,
  updated_by_user_id string attribute,
  created_at timestamp,
  updated_at timestamp
)
charset_table = 'non_cjk, cjk'
index_field_lengths = '1';
