#!/usr/bin/env bash

set -euo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

for cmd in curl jq nix nix-prefetch-url perl sed; do
  require_cmd "$cmd"
done

github_args=(-H "Accept: application/vnd.github+json")
raw_args=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  github_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  raw_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

github_json() {
  curl -fsSL "${github_args[@]}" "$1"
}

raw_text() {
  curl -fsSL "${raw_args[@]}" "$1"
}

latest_stable_release() {
  local page json line

  for page in $(seq 1 10); do
    json=$(github_json "https://api.github.com/repos/anyproto/anytype-ts/releases?per_page=100&page=${page}")
    line=$(
      jq -r '
        first(.[]
        | select(.draft == false)
        | select(.prerelease == false)
        | select((.tag_name | test("alpha|beta|nightly|rc"; "i")) | not)
        | [.tag_name, .created_at]
        | @tsv) // empty
      ' <<<"$json"
    )

    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return
    fi
  done

  echo "could not find a stable Anytype release" >&2
  exit 1
}

release_for_version() {
  local version=$1

  github_json "https://api.github.com/repos/anyproto/anytype-ts/releases/tags/v${version}" \
    | jq -r '[.tag_name, .created_at] | @tsv'
}

sri_for_unpacked_url() {
  local url=$1
  local nix32

  nix32=$(nix-prefetch-url --unpack --name source "$url" 2>/dev/null)
  nix hash convert --hash-algo sha256 --from nix32 --to sri "$nix32"
}

replace_version() {
  local file=$1
  local version=$2

  NEW_VERSION="$version" perl -0pi -e 's/version = "[^"]+";/version = "$ENV{NEW_VERSION}";/' "$file"
}

replace_nth_hash() {
  local file=$1
  local index=$2
  local hash=$3

  HASH="$hash" INDEX="$index" perl -0pi -e '
    my $i = 0;
    s/hash = "[^"]+";/(++$i == $ENV{INDEX}) ? "hash = \"$ENV{HASH}\";" : $&/ge;
  ' "$file"
}

replace_locales_rev() {
  local rev=$1

  REV="$rev" perl -0pi -e 's/rev = "[^"]+";/rev = "$ENV{REV}";/' pkgs/anytype/package.nix
}

set_vendor_hash() {
  local value=$1

  VALUE="$value" perl -0pi -e '
    s/vendorHash = (?:lib\.fakeHash|"[^"]+");/vendorHash = "$ENV{VALUE}";/;
  ' pkgs/anytype-heart/package.nix
}

set_vendor_hash_fake() {
  perl -0pi -e 's/vendorHash = (?:lib\.fakeHash|"[^"]+");/vendorHash = lib.fakeHash;/' \
    pkgs/anytype-heart/package.nix
}

set_node_modules_hash() {
  local value=$1

  VALUE="$value" perl -0pi -e '
    s/outputHash = (?:lib\.fakeHash|"[^"]+");/outputHash = "$ENV{VALUE}";/;
  ' pkgs/anytype/package.nix
}

set_node_modules_hash_fake() {
  perl -0pi -e 's/outputHash = (?:lib\.fakeHash|"[^"]+");/outputHash = lib.fakeHash;/' \
    pkgs/anytype/package.nix
}

discover_fixed_output_hash() {
  local attr=$1
  local output status hash

  set +e
  output=$(nix build "$attr" --no-link --print-build-logs 2>&1)
  status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    echo "expected a hash mismatch while building ${attr}, but the build succeeded" >&2
    exit 1
  fi

  hash=$(
    sed -nE 's/^[[:space:]]*got:[[:space:]]*(sha256-[A-Za-z0-9+/=]+).*/\1/p' <<<"$output" \
      | tail -n1
  )

  if [[ -z "$hash" ]]; then
    printf '%s\n' "$output" >&2
    echo "could not find computed hash in Nix output for ${attr}" >&2
    exit 1
  fi

  printf '%s\n' "$hash"
}

current_version=$(nix eval --raw .#anytype.version)

if [[ -n "${UPDATE_ANYTYPE_VERSION:-}" ]]; then
  IFS=$'\t' read -r release_tag release_date < <(release_for_version "$UPDATE_ANYTYPE_VERSION")
else
  IFS=$'\t' read -r release_tag release_date < <(latest_stable_release)
fi

anytype_version=${release_tag#v}

if [[ "$current_version" == "$anytype_version" && "${UPDATE_ANYTYPE_FORCE:-0}" != "1" ]]; then
  echo "Anytype ${anytype_version} is already current."
  exit 0
fi

echo "Updating Anytype ${current_version} -> ${anytype_version}"

locales_rev=$(
  github_json "https://api.github.com/repos/anyproto/l10n-anytype-ts/commits?until=${release_date}&per_page=1" \
    | jq -r '.[0].sha'
)

middleware_version=$(
  raw_text "https://raw.githubusercontent.com/anyproto/anytype-ts/refs/tags/v${anytype_version}/middleware.version" \
    | tr -d '[:space:]'
)

tantivy_go_version=$(
  raw_text "https://raw.githubusercontent.com/anyproto/anytype-heart/refs/tags/v${middleware_version}/go.mod" \
    | awk '
      /github.com\/anyproto\/tantivy-go/ && !found {
        gsub(/^v/, "", $2);
        print $2;
        found = 1;
      }
    '
)

if [[ -n "$tantivy_go_version" ]]; then
  current_tantivy_go_version=$(
    nix eval --raw --impure --expr '
      let
        flake = builtins.getFlake (toString ./.);
        pkgs = import flake.inputs.nixpkgs {
          system = builtins.currentSystem;
          config.allowUnfree = true;
          overlays = [ flake.outputs.overlays.default ];
        };
      in
        pkgs.tantivy-go.version
    '
  )

  if [[ "$current_tantivy_go_version" != "$tantivy_go_version" ]]; then
    echo "::warning::anytype-heart ${middleware_version} wants tantivy-go ${tantivy_go_version}; flake input provides ${current_tantivy_go_version}" >&2
  fi
fi

anytype_src_hash=$(
  sri_for_unpacked_url "https://github.com/anyproto/anytype-ts/archive/refs/tags/v${anytype_version}.tar.gz"
)
heart_src_hash=$(
  sri_for_unpacked_url "https://github.com/anyproto/anytype-heart/archive/refs/tags/v${middleware_version}.tar.gz"
)
locales_hash=$(
  sri_for_unpacked_url "https://github.com/anyproto/l10n-anytype-ts/archive/${locales_rev}.tar.gz"
)

replace_version pkgs/anytype/package.nix "$anytype_version"
replace_nth_hash pkgs/anytype/package.nix 1 "$anytype_src_hash"
replace_locales_rev "$locales_rev"
replace_nth_hash pkgs/anytype/package.nix 2 "$locales_hash"

replace_version pkgs/anytype-heart/package.nix "$middleware_version"
replace_nth_hash pkgs/anytype-heart/package.nix 1 "$heart_src_hash"

set_vendor_hash_fake
vendor_hash=$(discover_fixed_output_hash .#anytype-heart.goModules)
set_vendor_hash "$vendor_hash"

set_node_modules_hash_fake
node_modules_hash=$(discover_fixed_output_hash .#anytype.node_modules)
set_node_modules_hash "$node_modules_hash"

echo "Updated Anytype to ${anytype_version}"
echo "Updated Anytype Heart to ${middleware_version}"
