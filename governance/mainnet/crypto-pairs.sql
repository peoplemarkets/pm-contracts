-- Crypto pod pairs. Run against the PLATFORM postgres.
-- Framing rule: competition (chains/companies), never personal conflict.

INSERT INTO pair_definitions (id, long_subject_id, short_subject_id, label, narrative, active, display_order) VALUES
  ('jesse-vitalik','0x54ee7dc2425581581c47469e5eb1f5eed4233fcbddf6c7592f1580aa348c89b4','0x33fd3a1a2f6025be5b2d3026fea143df162bb647c138b6d16851023d3c6518a7','Base vs Ethereum','The L2 builder vs the L1 architect: whose ecosystem carries the cycle?',true,2),
  ('brian-cz','0xfa4dffc9e824f830cf7d07fc7765ba1d7b344d923dd9083258189156f4932796','0x41c2f8ee4055280a02ce6bacede0b367df1684b6390ec2e81c0b81681de3d1a8','Coinbase vs Binance','The two exchange titans, head to head on global mindshare.',true,3)
ON CONFLICT (id) DO UPDATE SET long_subject_id=EXCLUDED.long_subject_id, short_subject_id=EXCLUDED.short_subject_id, label=EXCLUDED.label, narrative=EXCLUDED.narrative, active=true;
