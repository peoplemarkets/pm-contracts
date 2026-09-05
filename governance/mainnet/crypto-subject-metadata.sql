-- Crypto pod: subject display metadata + the crypto category tab.
-- Run against the PLATFORM postgres (docker exec -i pm-platform-postgres ...).
-- subjectId = keccak256(display name); categoryId = keccak256('crypto').

INSERT INTO subject_metadata (subject_id, handle, category_slug, display_name_override) VALUES
  ('0x54ee7dc2425581581c47469e5eb1f5eed4233fcbddf6c7592f1580aa348c89b4', 'JessePollak', 'crypto', 'Jesse Pollak'),
  ('0xfa4dffc9e824f830cf7d07fc7765ba1d7b344d923dd9083258189156f4932796', 'BrianArmstrong', 'crypto', 'Brian Armstrong'),
  ('0x33fd3a1a2f6025be5b2d3026fea143df162bb647c138b6d16851023d3c6518a7', 'Vitalik', 'crypto', 'Vitalik Buterin'),
  ('0x41c2f8ee4055280a02ce6bacede0b367df1684b6390ec2e81c0b81681de3d1a8', 'CZ', 'crypto', 'CZ')
ON CONFLICT (subject_id) DO UPDATE SET category_slug=EXCLUDED.category_slug, display_name_override=EXCLUDED.display_name_override;

-- Category tab: slug -> on-chain categoryId so the UI can group the vertical.
INSERT INTO category_metadata (id, display_name, onchain_category_id, display_order) VALUES
  ('crypto', 'Crypto', '0x35006686fd78b85ed3fb52493d70cb3f7732177a19f352814df621b506c237a4', 3)
ON CONFLICT (id) DO UPDATE SET display_name=EXCLUDED.display_name, onchain_category_id=EXCLUDED.onchain_category_id;
