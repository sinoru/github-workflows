# Expands a package's short matrix spec into the full `include` list a build job can take whole
# through `fromJSON`. The spec says which Swift minors, which target triples and which build
# configurations; the catalog says what the first two stand for: the minor's current patch and
# Xcode, the triple's runner and display name, and the installer or Swift SDK it needs along
# with the checksum of that artifact for that patch.
#
# A Swift SDK is named to the build steps the way the catalog says: by the triple, where the
# bundle holds one SDK for it, or by an id template where it holds several. The WebAssembly
# bundle ships a regular and an Embedded SDK for one triple, and SwiftPM picks between them
# arbitrarily when given the triple, so its targets name the id: `{tag}_wasm`, where the tag is
# the toolchain's, `swift-6.3.3-RELEASE` for a release and `swift-DEVELOPMENT-SNAPSHOT-…` for a
# snapshot, which is how swift-sdk-generator names what it puts in a bundle. A release derives
# its tag from its patch; a snapshot entry in the catalog would carry one. The value is read
# after the row and the configuration have had their say, so a package can name another SDK
# from the same bundle, `{tag}_wasm-embedded`, or set `false` to build with none.
#
#   jq -c --argjson swift "$SWIFT" --argjson targets "$TARGETS" \
#      --argjson configurations "$CONFIGURATIONS" -f matrix.jq catalog.json
#
# `swift` is an array of minors. `targets` is an array whose entries are either a triple or an
# object with a `triple` key and qualifiers. Four qualifiers are read here: `swift` restricts
# the row to the minors it lists, `configurations` to the configurations it names, `runner`
# overrides the catalog's, and `runtime` pins a simulator row to an OS release ("16.4"), which
# names the CoreSimulator runtime to look for and the platform download that fetches it. Every
# other qualifier is passed into the row unchanged, which is how a package marks a row
# `experimental`, gives it a `sanitize`, or attaches anything else its own steps read.
#
# `configurations` is an array whose entries are either a name or an object with a `name` key
# and qualifiers, passed into the row the same way: `only` and `skip` are patterns over suite
# type names that say which suites that configuration runs or leaves out, so that a suite
# which only means something optimized can go to Release alone.
#
# Three qualifiers are command-line arguments, told apart by how far they reach: `arguments`
# go to every command in the row, `test_arguments` to the ones that build and run the tests,
# and `test_run_arguments` to the ones that run them. A configuration's keys otherwise
# overwrite a row's, and a row's the catalog's, but these are joined, in that order, so that
# the catalog can give a target what it always needs, a configuration can turn something on
# for every target, and a target can answer it: a define that lengthens the tests in Release,
# and another that shortens them again on a target that cannot afford them.
#
# Every row is emitted explicitly rather than as axes plus `include`, so nothing here depends
# on how GitHub merges an `include` entry into an axis combination, and a triple the package
# does not want is simply never emitted.

def labels:
  [ (if .sanitize == "thread" then "TSan" elif .sanitize == "address" then "ASan" else empty end),
    (if .skip_tests then "build only" else empty end),
    (if .experimental then "experimental" else empty end) ];

. as $catalog
| ($targets | map(if type == "string" then { triple: . } else . end)) as $rows
| ($configurations | map(if type == "string" then { name: . } else . end)) as $configurations
| { include: [
      $swift[] as $minor
      | ($catalog.swift[$minor] // error("Swift \($minor) is not in the catalog")) as $toolchain
      | ($toolchain.tag // "swift-\($toolchain.patch)-RELEASE") as $tag
      | $rows[]
      | select(.swift == null or (.swift | index($minor)))
      | . as $row
      | ($catalog.targets[$row.triple] // error("\($row.triple) is not in the catalog")) as $target
      | (if $target.artifact then $catalog.artifacts[$target.artifact] else null end) as $artifact
      | $configurations[] as $configuration
      | select($row.configurations == null or ($row.configurations | index($configuration.name)))
      | ($target | del(.name, .host, .runner, .os, .artifact))
        + ($row | del(.triple, .swift, .runtime, .configurations))
        + ($configuration | del(.name))
        + (reduce ("arguments", "test_arguments", "test_run_arguments") as $key ({};
             ([$target[$key], $row[$key], $configuration[$key]] | map(select(. != null))) as $parts
             | if ($parts | length) > 0 then . + { ($key): ($parts | join(" ")) } else . end))
        + (if $row.runtime
           then ($target.simulator_runtime // error("\($row.triple) has no simulator runtime to pin"))
                | { simulator_runtime: "\(.)-\($row.runtime | gsub("\\."; "-"))",
                    download_version: $row.runtime }
           else {} end)
        + { triple: $row.triple,
            swift: $minor,
            patch: $toolchain.patch,
            configuration: $configuration.name,
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
      | if .swift_sdk == true then .swift_sdk = .triple
        elif (.swift_sdk | type) == "string"
        then .swift_sdk |= (gsub("\\{tag\\}"; $tag) | gsub("\\{patch\\}"; $toolchain.patch))
        else del(.swift_sdk) end
      | . + { name: ((if $row.runtime then ($target.name | sub(" "; " \($row.runtime) ")) else $target.name end)
                     + " · Swift \($minor)"
                     + " · \($configuration.name)"
                     + (labels | if length > 0 then " (\(join(", ")))" else "" end)) }
  ] }
