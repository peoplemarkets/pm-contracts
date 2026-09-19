-- C12 music cohort expansion: The Weeknd, Billie Eilish, Bad Bunny,
-- Ariana Grande. Run against pm-platform-postgres AFTER the C12 Safe batch
-- executes (docker exec -i pm-platform-postgres psql -U pm -d pm_platform).
INSERT INTO subject_metadata (subject_id, handle, category_slug, display_name_override) VALUES
  ('0xd8b065863f55bb7e29eac9b1e3e8225f3f3c7726c361fe8ffcc18b835f683e50', 'TheWeeknd', 'music', 'The Weeknd'),
  ('0xf805e75277ea8866a01e57963dafa59ac6bb8446640b723388af25a985da4ff7', 'BillieEilish', 'music', 'Billie Eilish'),
  ('0xb40f02e23e6c2ad6e039a2340ff04fbdeda31ef2a24a715be91e664193a6c1f7', 'BadBunny', 'music', 'Bad Bunny'),
  ('0x1487da92e71f82e62d2882e1dd0b17ae0b34130884e785412c8755a01a8c572a', 'ArianaGrande', 'music', 'Ariana Grande')
ON CONFLICT (subject_id) DO UPDATE SET category_slug=EXCLUDED.category_slug, display_name_override=EXCLUDED.display_name_override;
