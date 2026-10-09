# Expands a package's short matrix spec into the full `include` list a build job can take whole
# through `fromJSON`. The spec says which Swift minors and which target triples; the catalog
# says what each of those stands for: the minor's current patch and Xcode, the triple's runner
# and display name, and the installer or Swift SDK it needs along with the checksum of that
# artifact for that patch.
#
#   jq -c --argjson swift "$SWIFT" --argjson targets "$TARGETS" -f matrix.jq catalog.json
#
# `swift` is an array of minors. `targets` is an array whose entries are either a triple or an
# object with a `triple` key and qualifiers. Three qualifiers are read here: `swift` restricts
# the row to the minors it lists, `runner` overrides the catalog's, and `runtime` pins a
# simulator row to an OS release ("16.4"), which names the CoreSimulator runtime to look for
# and the platform download that fetches it. Every other qualifier is passed into the row
# unchanged, which is how a package marks a row `experimental`, gives it a `sanitize`, or
# attaches anything else its own steps read.
#
# Every row is emitted explicitly rather than as axes plus `include`, so nothing here depends
# on how GitHub merges an `include` entry into an axis combination, and a pair the package does
# not want is simply never emitted.

def labels:
  [ (if .sanitize == "thread" then "TSan" elif .sanitize == "address" then "ASan" else empty end),
    (if .skip_tests then "build only" else empty end),
    (if .experimental then "experimental" else empty end) ];

. as $catalog
| ($targets | map(if type == "string" then { triple: . } else . end)) as $rows
| { include: [
      $swift[] as $minor
      | ($catalog.swift[$minor] // error("Swift \($minor) is not in the catalog")) as $toolchain
      | $rows[]
      | select(.swift == null or (.swift | index($minor)))
      | . as $row
      | ($catalog.targets[$row.triple] // error("\($row.triple) is not in the catalog")) as $target
      | (if $target.artifact then $catalog.artifacts[$target.artifact] else null end) as $artifact
      | ($target | del(.name, .host, .runner, .os, .artifact))
        + ($row | del(.triple, .swift, .runtime))
        + (if $row.runtime
           then ($target.simulator_runtime // error("\($row.triple) has no simulator runtime to pin"))
                | { simulator_runtime: "\(.)-\($row.runtime | gsub("\\."; "-"))",
                    download_version: $row.runtime }
           else {} end)
        + { triple: $row.triple,
            swift: $minor,
            patch: $toolchain.patch,
            runner: ($row.runner // $target.runner // $toolchain.macos_runner),
            os: ($target.os // $toolchain.macos) }
        + (if $target.host == "macos"
           then { developer_dir: "/Applications/Xcode_\($toolchain.xcode).app/Contents/Developer" }
           else {} end)
        + (if $artifact
           then { artifact_url: ($artifact.url | gsub("\\{patch\\}"; $toolchain.patch)),
                  artifact_sha256: ($artifact.sha256[$toolchain.patch]
                    // error("no checksum for \($target.artifact) \($toolchain.patch)")) }
           else {} end)
      | . + { name: ((if $row.runtime then ($target.name | sub(" "; " \($row.runtime) ")) else $target.name end)
                     + " · Swift \($minor)"
                     + (labels | if length > 0 then " (\(join(", ")))" else "" end)) }
  ] }
