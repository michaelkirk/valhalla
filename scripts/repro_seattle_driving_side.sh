#!/usr/bin/env bash
# Builds valhalla and a Seattle tileset (with admins) from a BBBike extract, then reports the driving side.
#
# usage, from the repo root: scripts/repro_seattle_driving_side.sh [build_dir]
# Needs cmake, curl, python3 and sqlite3.
set -euo pipefail

BUILD=${1:-build}
WORK=$BUILD/repro_seattle_driving_side
PBF_URL=https://download.bbbike.org/osm/bbbike/Seattle/Seattle.osm.pbf

if [[ ! -f $BUILD/CMakeCache.txt ]]; then
  cmake -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DENABLE_SERVICES=OFF -DENABLE_TESTS=OFF
fi
cmake --build "$BUILD" --parallel --target valhalla_build_admins valhalla_build_tiles valhalla_service

mkdir -p "$WORK"
[[ -f $WORK/Seattle.osm.pbf ]] || curl -fL -o "$WORK/Seattle.osm.pbf" "$PBF_URL"

rm -rf "$WORK/tiles" "$WORK/admins.sqlite"
mkdir "$WORK/tiles"
python3 scripts/valhalla_build_config --mjolnir-tile-dir "$WORK/tiles" \
  --mjolnir-tile-extract "$WORK/none.tar" --mjolnir-admin "$WORK/admins.sqlite" \
  --mjolnir-timezone "$WORK/none.sqlite" > "$WORK/valhalla.json"

echo "Building admins and tiles..."
"$BUILD/valhalla_build_admins" -c "$WORK/valhalla.json" "$WORK/Seattle.osm.pbf" > "$WORK/build_admins.log" 2>&1
"$BUILD/valhalla_build_tiles" -c "$WORK/valhalla.json" "$WORK/Seattle.osm.pbf" > "$WORK/build_tiles.log" 2>&1

service() { "$BUILD/valhalla_service" "$WORK/valhalla.json" "$@" 2>/dev/null; }

echo
echo "== admins.sqlite: $(sqlite3 "$WORK/admins.sqlite" 'select count(*) from admins') admins"
sqlite3 "$WORK/admins.sqlite" "select admin_level, name, drive_on_right from admins"

locate() {
  service locate "{\"locations\":[{\"lat\":$1,\"lon\":$2}],\"costing\":\"auto\",\"verbose\":true}"
}

# Only a location that snaps to a node returns node info, so locate the first point of the nearest edge.
node_side() {
  local name=$1 node
  node=$(locate "$2" "$3" | python3 -I -c '
import json, sys
shape = json.load(sys.stdin)[0]["edges"][0]["edge_info"]["shape"]
i = 0
coords = []
for _ in range(2):
    result = shift = 0
    while True:
        b = ord(shape[i]) - 63
        i += 1
        result |= (b & 31) << shift
        shift += 5
        if b < 32:
            break
    coords.append(~(result >> 1) if result & 1 else result >> 1)
print(coords[0] / 1e6, coords[1] / 1e6)')
  locate $node | python3 -I -c '
import json, sys
dor = str(json.load(sys.stdin)[0]["nodes"][0]["drive_on_right"]).lower()
print(f"{sys.argv[1]:<18} drive_on_right={dor}")' "$name"
}

echo
echo "== nodes"
node_side "Downtown Seattle" 47.6062 -122.3321
node_side "Capitol Hill" 47.6253 -122.3222
node_side "Ballard" 47.6687 -122.3843

echo
echo "== route to Capitol Hill with preferred_side=same"
service route '{"locations":[{"lat":47.6097,"lon":-122.3425},{"lat":47.6150,"lon":-122.3200,"preferred_side":"same"}],"costing":"auto"}' |
  python3 -I -c 'import json, sys; print(json.load(sys.stdin)["trip"]["legs"][0]["maneuvers"][-1]["instruction"])'
