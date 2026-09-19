#!/bin/sh
# C12 music cohort expansion — composer config for the four new acts.
# Run on the VPS at ~/pm-engine AFTER the C12 Safe batch + metadata SQL.
# Appends the subjects to deploy/local.yaml's composer.subjects list, then
# restarts the composer (config is a bind-mount; no rebuild needed).
#
# Spotify artist IDs verified against open.spotify.com pages 2026-07-28.
# Wikipedia titles are the canonical article names. gdelt: full public name
# (never a bare first name). No x:/youtube: — same posture as the existing
# music acts (quorum = Streaming + Search + News groups).
set -e
cd ~/pm-engine
cp deploy/local.yaml "deploy/local.yaml.bak.$(date +%s)"

cat >> deploy/local.yaml << 'YAML'
    - id: "0xd8b065863f55bb7e29eac9b1e3e8225f3f3c7726c361fe8ffcc18b835f683e50"
      handle: "The Weeknd"
      vertical: "music"
      spotify: "1Xyo4u8uXC1ZmMpatF05PJ"
      wikipedia: "The Weeknd"
      gdelt: "The Weeknd"
    - id: "0xf805e75277ea8866a01e57963dafa59ac6bb8446640b723388af25a985da4ff7"
      handle: "Billie Eilish"
      vertical: "music"
      spotify: "6qqNVTkY8uBg9cP3Jd7DAH"
      wikipedia: "Billie Eilish"
      gdelt: "Billie Eilish"
    - id: "0xb40f02e23e6c2ad6e039a2340ff04fbdeda31ef2a24a715be91e664193a6c1f7"
      handle: "Bad Bunny"
      vertical: "music"
      spotify: "4q3ewBCX7sLwd24euuV69X"
      wikipedia: "Bad Bunny"
      gdelt: "Bad Bunny"
    - id: "0x1487da92e71f82e62d2882e1dd0b17ae0b34130884e785412c8755a01a8c572a"
      handle: "Ariana Grande"
      vertical: "music"
      spotify: "66CXWjxzNUsdJxJ2JdwvnR"
      wikipedia: "Ariana Grande"
      gdelt: "Ariana Grande"
YAML

echo "Appended 4 music subjects. Verify indentation matches the existing"
echo "composer.subjects entries (this heredoc assumes subjects are the LAST"
echo "section of the file — eyeball before restarting):"
grep -A2 'The Weeknd' deploy/local.yaml | head -6
echo
echo "Then: docker compose -f docker-compose.prod.yml restart composer"
