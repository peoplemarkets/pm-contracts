-- Politics pod: subject display metadata + politics category tab + pairs.
-- Run against the PLATFORM postgres (docker exec -i pm-platform-postgres ...).
-- subjectId = keccak256(display name); categoryId = keccak256('politics').
-- Non-US figures only (2026 US election year — US_POLITICIAN_ELECTION_YEAR
-- policy flag deliberately not engaged).

INSERT INTO subject_metadata (subject_id, handle, category_slug, display_name_override) VALUES
  ('0x2f705861126468521fdae372898dd08249a79a312f1ffcc83dcb43bbedb33bd4', 'Milei', 'politics', 'Javier Milei'),
  ('0xca58fcca5efd55ababb1e46397133ca6655dc66c12c0ae860b1c8bd1518eeb3c', 'Zelenskyy', 'politics', 'Volodymyr Zelenskyy'),
  ('0x7b8af8c7cd16b90370d1f6cb5cc5d184224b1f4ec3fbb3586da0d2af2242ebee', 'Macron', 'politics', 'Emmanuel Macron'),
  ('0x1b43724599650543be026e236a93553a5a50de0bb9c061724cfefe46c71b7982', 'Meloni', 'politics', 'Giorgia Meloni'),
  ('0x47f1b537e17cffa3dd7d139018eacbeeb2a516c3d16e128cf7862ea7cdc131ae', 'Starmer', 'politics', 'Keir Starmer')
ON CONFLICT (subject_id) DO UPDATE SET category_slug=EXCLUDED.category_slug, display_name_override=EXCLUDED.display_name_override;

INSERT INTO category_metadata (id, display_name, onchain_category_id, display_order) VALUES
  ('politics', 'Politics', '0x244cf72cb284fc7d430637a0d0fe497a88146c8eb8832a06e8aaf72bcb0f75c8', 4)
ON CONFLICT (id) DO UPDATE SET display_name=EXCLUDED.display_name, onchain_category_id=EXCLUDED.onchain_category_id;

-- Pairs: competition on relevance/mindshare only — never endorsement,
-- never personal conflict. Framing rule matters most in this vertical.
INSERT INTO pair_definitions (id, long_subject_id, short_subject_id, label, narrative, active, display_order) VALUES
  ('milei-macron','0x2f705861126468521fdae372898dd08249a79a312f1ffcc83dcb43bbedb33bd4','0x7b8af8c7cd16b90370d1f6cb5cc5d184224b1f4ec3fbb3586da0d2af2242ebee','Libertarian vs Establishment','Two opposite theories of the state, measured in global mindshare.',true,4),
  ('meloni-starmer','0x1b43724599650543be026e236a93553a5a50de0bb9c061724cfefe46c71b7982','0x47f1b537e17cffa3dd7d139018eacbeeb2a516c3d16e128cf7862ea7cdc131ae','Rome vs London','Europe''s two most-watched governments, head to head on attention.',true,5)
ON CONFLICT (id) DO UPDATE SET long_subject_id=EXCLUDED.long_subject_id, short_subject_id=EXCLUDED.short_subject_id, label=EXCLUDED.label, narrative=EXCLUDED.narrative, active=true;
