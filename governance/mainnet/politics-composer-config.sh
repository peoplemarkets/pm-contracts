#!/bin/sh
# Politics pod -> composer config. Run ON THE VPS after C11 executes.
# Appends five subjects to composer.subjects in ~/pm-engine/deploy/local.yaml
# (printf-per-line avoids the heredoc paste-truncation trap).
#
# Sources: x (Social) + google_trends + wikipedia (Search) for all five —
# verified 2026-07-21: @JMilei, @ZelenskyyUa, @EmmanuelMacron, @GiorgiaMeloni,
# @Keir_Starmer (underscore; beware the @pmkeirstarmer decoy). Wikipedia titles
# are the plain names. GEOMETRY NOTE: Starmer's wiki pageviews run ~9x the pod
# floor right now (news-cycle inflated) — he will rank #1 on that metric and
# compress the others there; acceptable within-vertical, watch after listing.
#
# PREREQ: X credits + scrape.do quota must be funded, or this pod holds forever
# (same dual-quota exhaustion that stalled the crypto pod on 2026-07-21).

Y=~/pm-engine/deploy/local.yaml

printf '    - id: "0x2f705861126468521fdae372898dd08249a79a312f1ffcc83dcb43bbedb33bd4"\n' >> $Y
printf '      handle: Javier Milei\n' >> $Y
printf '      vertical: "politics"\n' >> $Y
printf '      x: "JMilei"\n' >> $Y
printf '      google_trends: "Javier Milei"\n' >> $Y
printf '      wikipedia: "Javier Milei"\n' >> $Y

printf '    - id: "0xca58fcca5efd55ababb1e46397133ca6655dc66c12c0ae860b1c8bd1518eeb3c"\n' >> $Y
printf '      handle: Volodymyr Zelenskyy\n' >> $Y
printf '      vertical: "politics"\n' >> $Y
printf '      x: "ZelenskyyUa"\n' >> $Y
printf '      google_trends: "Volodymyr Zelenskyy"\n' >> $Y
printf '      wikipedia: "Volodymyr Zelenskyy"\n' >> $Y

printf '    - id: "0x7b8af8c7cd16b90370d1f6cb5cc5d184224b1f4ec3fbb3586da0d2af2242ebee"\n' >> $Y
printf '      handle: Emmanuel Macron\n' >> $Y
printf '      vertical: "politics"\n' >> $Y
printf '      x: "EmmanuelMacron"\n' >> $Y
printf '      google_trends: "Emmanuel Macron"\n' >> $Y
printf '      wikipedia: "Emmanuel Macron"\n' >> $Y

printf '    - id: "0x1b43724599650543be026e236a93553a5a50de0bb9c061724cfefe46c71b7982"\n' >> $Y
printf '      handle: Giorgia Meloni\n' >> $Y
printf '      vertical: "politics"\n' >> $Y
printf '      x: "GiorgiaMeloni"\n' >> $Y
printf '      google_trends: "Giorgia Meloni"\n' >> $Y
printf '      wikipedia: "Giorgia Meloni"\n' >> $Y

printf '    - id: "0x47f1b537e17cffa3dd7d139018eacbeeb2a516c3d16e128cf7862ea7cdc131ae"\n' >> $Y
printf '      handle: Keir Starmer\n' >> $Y
printf '      vertical: "politics"\n' >> $Y
printf '      x: "Keir_Starmer"\n' >> $Y
printf '      google_trends: "Keir Starmer"\n' >> $Y
printf '      wikipedia: "Keir Starmer"\n' >> $Y

echo "--- appended; verify the tail parses as YAML: ---"
tail -32 $Y
