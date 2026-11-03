#!/bin/bash
# Writes App/Acknowledgements.txt, the licence of every library pinned in
# Packages/CalloutKit/Package.resolved, which the About panel shows. Their
# licences require it in every copy of the app we hand out.
#
#     scripts/make-acknowledgements.sh            rewrite the file
#     scripts/make-acknowledgements.sh --check    fail if the file is out of date
#
# Run from the repo root.
set -euo pipefail

package=Packages/CalloutKit
resolved=$package/Package.resolved
output=App/Acknowledgements.txt

swift package resolve --package-path "$package" >/dev/null

generate() {
    echo "Callout uses these libraries. Each one's licence follows."
    local count i location version name checkout found file
    count=$(plutil -extract pins raw -o - "$resolved")
    for ((i = 0; i < count; i++)); do
        location=$(plutil -extract "pins.$i.location" raw -o - "$resolved")
        version=$(plutil -extract "pins.$i.state.version" raw -o - "$resolved")
        name=$(basename "$location" .git)
        checkout=$package/.build/checkouts/$name
        printf '\n\n%s %s\n%s\n' "$name" "$version" "${location%.git}"
        found=no
        for file in LICENSE LICENSE.txt LICENSE.md COPYING NOTICE NOTICE.txt; do
            [ -f "$checkout/$file" ] || continue
            printf '\n'
            cat "$checkout/$file"
            found=yes
        done
        if [ "$found" = no ]; then
            echo "make-acknowledgements: no licence file in $checkout" >&2
            exit 1
        fi
    done
}

if [ "${1:-}" = --check ]; then
    if ! generate | cmp -s - "$output"; then
        echo "$output is out of date. Run scripts/make-acknowledgements.sh and commit it." >&2
        exit 1
    fi
else
    generate > "$output"
    echo "Wrote $output"
fi
