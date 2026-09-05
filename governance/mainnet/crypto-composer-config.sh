#!/bin/sh
# Crypto pod -> composer config. Run ON THE VPS. Appends four subjects to the
# composer.subjects list in ~/pm-engine/deploy/local.yaml (subjects is the last
# section of the file, so appending continues the list — same technique as the
# music-acts listing; printf-per-line avoids the heredoc paste-truncation trap).
#
# Sources per subject: x (mentions+followers, Social) + google_trends + wikipedia
# (Search). Jesse Pollak has NO Wikipedia article (verified 2026-07-21) so he
# runs x+trends only — still 2 groups, meets required=2/min_groups=2.
# All X handles verified 2026-07-21: @jessepollak (NOT @jesse), @brian_armstrong,
# @VitalikButerin, @cz_binance. Wikipedia: "Brian Armstrong (businessman)" (NOT
# "(executive)"). Trends for Brian is disambiguated with "Coinbase" (the plain
# name collides with other public Brian Armstrongs).

Y=~/pm-engine/deploy/local.yaml

printf '    - id: "0x54ee7dc2425581581c47469e5eb1f5eed4233fcbddf6c7592f1580aa348c89b4"\n' >> $Y
printf '      handle: Jesse Pollak\n' >> $Y
printf '      vertical: "crypto"\n' >> $Y
printf '      x: "jessepollak"\n' >> $Y
printf '      google_trends: "Jesse Pollak"\n' >> $Y

printf '    - id: "0xfa4dffc9e824f830cf7d07fc7765ba1d7b344d923dd9083258189156f4932796"\n' >> $Y
printf '      handle: Brian Armstrong\n' >> $Y
printf '      vertical: "crypto"\n' >> $Y
printf '      x: "brian_armstrong"\n' >> $Y
printf '      google_trends: "Brian Armstrong Coinbase"\n' >> $Y
printf '      wikipedia: "Brian Armstrong (businessman)"\n' >> $Y

printf '    - id: "0x33fd3a1a2f6025be5b2d3026fea143df162bb647c138b6d16851023d3c6518a7"\n' >> $Y
printf '      handle: Vitalik Buterin\n' >> $Y
printf '      vertical: "crypto"\n' >> $Y
printf '      x: "VitalikButerin"\n' >> $Y
printf '      google_trends: "Vitalik Buterin"\n' >> $Y
printf '      wikipedia: "Vitalik Buterin"\n' >> $Y

printf '    - id: "0x41c2f8ee4055280a02ce6bacede0b367df1684b6390ec2e81c0b81681de3d1a8"\n' >> $Y
printf '      handle: CZ\n' >> $Y
printf '      vertical: "crypto"\n' >> $Y
printf '      x: "cz_binance"\n' >> $Y
printf '      google_trends: "Changpeng Zhao"\n' >> $Y
printf '      wikipedia: "Changpeng Zhao"\n' >> $Y

echo "--- appended; verify the tail parses as YAML: ---"
tail -26 $Y
