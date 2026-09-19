INSERT INTO subject_metadata (subject_id, handle, category_slug, display_name_override) VALUES
  ('0x955d1148a9f65eb07a602c1b6f2b110d249c2775a94cf36cec489ace0c234e44', 'MrBeast', 'creator', 'MrBeast'),
  ('0xb9fbf7672f3f76f2b16a062c23a322d63a03e65c86837bada0e5f247ad641e24', 'IShowSpeed', 'creator', 'IShowSpeed'),
  ('0x714a8b2434b3ed5ac083a45bf03ed620f0c2c10cbc864d69270f34bc7599be8f', 'KaiCenat', 'creator', 'Kai Cenat')
ON CONFLICT (subject_id) DO UPDATE SET category_slug=EXCLUDED.category_slug, display_name_override=EXCLUDED.display_name_override;
