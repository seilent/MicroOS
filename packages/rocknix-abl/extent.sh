le32() { od -An -tu4 -j"$2" -N4 "$1" | tr -d ' \n'; }
le16() { od -An -tu2 -j"$2" -N2 "$1" | tr -d ' \n'; }

extent() {
  local f=$1 phoff phentsize phnum shoff shentsize shnum l i o e
  phoff=$(le32 "$f" 28)
  phentsize=$(le16 "$f" 42)
  phnum=$(le16 "$f" 44)
  shoff=$(le32 "$f" 32)
  shentsize=$(le16 "$f" 46)
  shnum=$(le16 "$f" 48)
  l=$((shoff + shnum * shentsize))
  for ((i = 0; i < phnum; i++)); do
    o=$((phoff + i * phentsize))
    e=$(( $(le32 "$f" $((o + 4))) + $(le32 "$f" $((o + 16))) ))
    (( e <= l )) || l=$e
  done
  printf '%s\n' "$l"
}
