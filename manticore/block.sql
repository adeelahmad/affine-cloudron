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
morphology = 'jieba_chinese, lemmatize_en_all, lemmatize_de_all, lemmatize_ru_all, libstemmer_ar, libstemmer_ca, stem_cz, libstemmer_da, libstemmer_nl, libstemmer_fi, libstemmer_fr, libstemmer_el, libstemmer_hi, libstemmer_hu, libstemmer_id, libstemmer_ga, libstemmer_it, libstemmer_lt, libstemmer_ne, libstemmer_no, libstemmer_pt, libstemmer_ro, libstemmer_es, libstemmer_sv, libstemmer_ta, libstemmer_tr'
charset_table = 'non_cjk, cjk'
index_field_lengths = '1';
