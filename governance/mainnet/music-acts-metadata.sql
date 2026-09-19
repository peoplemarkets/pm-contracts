INSERT INTO subject_metadata (subject_id, handle, category_slug, display_name_override) VALUES
  ('0x3792295b8834f8dd4831ec6735012a70973cd907d3f5cbf9070a117cfd06f81a', 'BTS', 'music', 'BTS'),
  ('0xaff5b244448b7c637efee0fe80267cfb70295ea3dfb4f4e12d29b9c70d4419ce', 'BLACKPINK', 'music', 'BLACKPINK'),
  ('0x2294515513cf788331bd63a3f6891627600fa854c25d965d8767bf65d5b857f7', 'TaylorSwift', 'music', 'Taylor Swift'),
  ('0x928f15f0c2b88504b1268df4bfdfe6fbf3906fc378bacc83aee63d21116dcaa3', 'Drake', 'music', 'Drake')
ON CONFLICT (subject_id) DO UPDATE SET category_slug=EXCLUDED.category_slug, display_name_override=EXCLUDED.display_name_override;
