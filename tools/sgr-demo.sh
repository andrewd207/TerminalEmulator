#!/usr/bin/env bash
# SGR feature exercise. Pipe straight into the terminal under test.
# Usage: ./sgr-demo.sh   (or:  ./sgr-demo.sh | cat -)

E=$'\e'
CSI="${E}["
R="${CSI}0m"

echo
echo "=== Basic attributes ==="
printf '%sbold%s   %sfaint%s   %sitalic%s   %sunderline%s   %sblink%s   %sinverse%s   %shidden%s%shidden+marker(should be invisible)%s   %sstrike%s\n' \
  "${CSI}1m" "$R" "${CSI}2m" "$R" "${CSI}3m" "$R" "${CSI}4m" "$R" \
  "${CSI}5m" "$R" "${CSI}7m" "$R" "${CSI}8m" "${CSI}8m" "$R" "${CSI}9m" "$R"

echo
echo "=== Attribute combos ==="
printf '%sbold+italic%s  %sbold+underline%s  %sfaint+italic%s  %sbold+strike%s  %sitalic+underline%s\n' \
  "${CSI}1;3m" "$R" "${CSI}1;4m" "$R" "${CSI}2;3m" "$R" "${CSI}1;9m" "$R" "${CSI}3;4m" "$R"

echo
echo "=== 16-color foreground (30-37, 90-97) ==="
for i in 30 31 32 33 34 35 36 37; do printf '%s%2d ' "${CSI}${i}m" "$i"; done; printf '%s\n' "$R"
for i in 90 91 92 93 94 95 96 97; do printf '%s%2d ' "${CSI}${i}m" "$i"; done; printf '%s\n' "$R"

echo
echo "=== 16-color background (40-47, 100-107) ==="
for i in 40 41 42 43 44 45 46 47; do printf '%s %2d %s ' "${CSI}${i}m" "$i" "$R"; done; echo
for i in 100 101 102 103 104 105 106 107; do printf '%s %3d %s ' "${CSI}${i}m" "$i" "$R"; done; echo

echo
echo "=== 256-color foreground ramp ==="
for i in 16 52 88 124 160 196 202 208 214 220 226 190 154 118 82 46 47 48 49 50 51; do
  printf '%s %3d %s' "${CSI}38;5;${i}m" "$i" "$R"
done
echo

echo
echo "=== Truecolor gradient (RGB) ==="
for i in $(seq 0 7 255); do
  printf '%s##%s' "${CSI}38;2;${i};128;$((255 - i))m" "$R"
done
echo

echo
echo "=== Wide / combining ==="
printf 'CJK: %s 你好世界 %s  Emoji: 😀🚀✨  Combining: e\xcc\x81 (e+acute)\n' "${CSI}1m" "$R"

echo
echo "=== Box drawing ==="
printf '┌───────────┬───────────┐\n│ %sbold%s      │ %sitalic%s    │\n├───────────┼───────────┤\n│ %sunderlined%s│ %sreversed%s  │\n└───────────┴───────────┘\n' \
  "${CSI}1m" "$R" "${CSI}3m" "$R" "${CSI}4m" "$R" "${CSI}7m" "$R"

echo
echo "=== Cursor save/restore + relative moves ==="
printf 'before%s' "${CSI}s"     # save
printf '%s' "${CSI}10C[+10 cols]"
printf '%sback' "${CSI}u"        # restore
echo
echo

echo "=== Done. ==="
