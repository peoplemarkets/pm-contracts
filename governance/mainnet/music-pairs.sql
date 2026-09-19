INSERT INTO pair_definitions (id, long_subject_id, short_subject_id, label, narrative, active, display_order) VALUES
  ('bts-blackpink','0x3792295b8834f8dd4831ec6735012a70973cd907d3f5cbf9070a117cfd06f81a','0xaff5b244448b7c637efee0fe80267cfb70295ea3dfb4f4e12d29b9c70d4419ce','K-pop Supremacy','The defining K-pop rivalry: BTS vs BLACKPINK.',true,0),
  ('swift-drake','0x2294515513cf788331bd63a3f6891627600fa854c25d965d8767bf65d5b857f7','0x928f15f0c2b88504b1268df4bfdfe6fbf3906fc378bacc83aee63d21116dcaa3','Pop vs Rap','The two biggest streaming acts on earth, head to head.',true,1)
ON CONFLICT (id) DO UPDATE SET long_subject_id=EXCLUDED.long_subject_id, short_subject_id=EXCLUDED.short_subject_id, label=EXCLUDED.label, narrative=EXCLUDED.narrative, active=true;
