#!/bin/zsh
# Mean/min fps of BG3 from the Metal HUD log, over the last N seconds (default
# 10) or between START and END ("YYYY-MM-DD HH:MM:SS"). Requires the game
# launched with MTL_HUD_LOG_ENABLED=1. Each HUD line carries the frame counter;
# the HUD logs about once a second but not exactly, so rates use the lines'
# timestamps.
if [[ $# -ge 2 ]]; then
  range=(--start "$1" --end "$2")
else
  range=(--last $((${1:-10}+1))s)
fi
/usr/bin/log show "${range[@]}" --predicate 'category == "Logging" AND process == "Baldur'"'"'s Gate 3"' 2>/dev/null |
  sed -nE 's/^[0-9-]+ ([0-9]+):([0-9]+):([0-9.]+)[-+][0-9]+ .*metal-HUD: ([0-9]+),.*/\1 \2 \3 \4/p' |
  awk '{t=$1*3600+$2*60+$3; c=$4}
       NR>1 && t>pt {r=(c-pc)/(t-pt); if(min==""||r<min)min=r}
       NR==1 {t0=t; c0=c} {pt=t; pc=c}
       END{if(NR>1 && pt>t0) printf "fps mean %.1f min %.1f over %.1fs\n", (pc-c0)/(pt-t0), min, pt-t0; else print "no HUD data"}'
