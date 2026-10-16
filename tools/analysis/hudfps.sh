#!/bin/zsh
# Mean/min fps of BG3 from the Metal HUD log over the last N seconds (default 10).
# Requires the game launched with MTL_HUD_LOG_ENABLED=1.
N=${1:-10}
/usr/bin/log show --last $((N+1))s --predicate 'category == "Logging" AND process == "Baldur'"'"'s Gate 3"' 2>/dev/null |
  sed -nE 's/.*metal-HUD: ([0-9]+),.*/\1/p' |
  awk 'NR>1{d=$1-p; s+=d; n++; if(min==""||d<min)min=d} {p=$1} END{if(n) printf "fps mean %.1f min %d over %ds\n", s/n, min, n; else print "no HUD data"}'
