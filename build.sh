#!/bin/bash
# Builds the repository into ./site (what GitHub Pages serves): downloads the
# debs named in repos.txt, writes each suite's package lists and a signed
# Release. Needs gh, apt-utils (apt-ftparchive), gpg. The signing key is
# imported from $APT_GPG_KEY (armored private key) when set.
set -euo pipefail
cd "$(dirname "$0")"

SUITES="unstable testing stable"
COMPONENTS="main extra"
ARCHES="amd64 arm64"
OUT=site

rm -rf "$OUT" .cache; mkdir -p "$OUT" .cache
for s in $SUITES; do for c in $COMPONENTS; do mkdir -p "$OUT/pool/$s/$c"; done; done

while read -r suite comp src tag; do
    case $suite in ''|\#*) continue ;; esac
    if [ "$tag" = latest ]; then
        tag=$(gh release list -R "$src" --exclude-drafts -L 1 --json tagName -q '.[0].tagName')
        [ -n "$tag" ] || { echo "no release in $src" >&2; exit 1; }
    fi
    echo "$suite/$comp: $src $tag"
    gh release download "$tag" -R "$src" --pattern '*.deb' --dir "$OUT/pool/$suite/$comp" --clobber
done < repos.txt

for s in $SUITES; do
    [ -d "extra-debs/$s" ] && cp extra-debs/"$s"/*.deb "$OUT/pool/$s/extra/" 2>/dev/null || true
done

for s in $SUITES; do
    for c in $COMPONENTS; do
        for a in $ARCHES; do
            d="$OUT/dists/$s/$c/binary-$a"
            mkdir -p "$d"
            apt-ftparchive --arch "$a" packages "$OUT/pool/$s/$c" | sed "s|^Filename: $OUT/|Filename: |" > "$d/Packages"
            gzip -9kn "$d/Packages"
            xz -9k "$d/Packages"
        done
    done
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=HeroineOS \
        -o APT::FTPArchive::Release::Label=HeroineOS \
        -o APT::FTPArchive::Release::Suite="$s" \
        -o APT::FTPArchive::Release::Codename="$s" \
        -o APT::FTPArchive::Release::Architectures="$ARCHES" \
        -o APT::FTPArchive::Release::Components="$COMPONENTS" \
        release "$OUT/dists/$s" > .cache/Release
    mv .cache/Release "$OUT/dists/$s/Release"
done

if [ -n "${APT_GPG_KEY:-}" ]; then
    export GNUPGHOME; GNUPGHOME=$(mktemp -d)
    printf '%s\n' "$APT_GPG_KEY" | gpg --batch --quiet --import
    for s in $SUITES; do
        r="$OUT/dists/$s"
        gpg --batch --yes --pinentry-mode loopback --armor --detach-sign -o "$r/Release.gpg" "$r/Release"
        gpg --batch --yes --pinentry-mode loopback --clearsign -o "$r/InRelease" "$r/Release"
    done
else
    echo "no APT_GPG_KEY: the Release files are not signed" >&2
fi

cp heroineos.gpg index.html "$OUT/"
echo done
