# monnect config – copy to config.sh and fill in (or let setup.sh generate it)
DEVICES=(
  "aa-bb-cc-dd-ee-ff"  # Magic Mouse    (find addresses with: blueutil --paired)
  "11-22-33-44-55-66"  # Magic Keyboard
)
# SSH target for the OTHER Mac, e.g. "user@Other-Mac.local" (empty = local only)
PEER_HOST=""
# Where these scripts live on the other Mac
PEER_MONNECT_DIR=""
