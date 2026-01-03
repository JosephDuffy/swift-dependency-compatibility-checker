# Swift Dependency Compatibility Checker

The swift-dependency-compatibility-checker package provides a tool for resolving the supported range of a Swift dependency, optionally running tests against each version, with the goal of ensuring a package's stated range for a dependency is supported.

This was created to ensure compatibility with [Swift Syntax](https://github.com/swiftlang/swift-syntax) for macros, where we often do not need the latest package but want to declare a wide range to provide greater compatibility with other macros.

## Usage

There are 2 primary uses for this package. For running locally it can iterate through all the supported versions for a package and run the tests.

```bash
swift run swift-dependency-compatibility-checker --package-path ../HashableMacro/ swift-syntax
```

This will:

- Resolve all the versions of `swift-syntax` supported by the package at `../HashableMacro/`
- For every supported version:
  - Copy the package at `../HashableMacro/` to a temporary directory
  - Resolve the `swift-syntax` package to the specific version
  - Run `swift test`

This defaults to running these checks sequentially because Swift will not do some tasks in parallel, for example resolving packages. I didn't find much an improvement running them in parallel, but you can pass `--num-tests 2` to run 2 (or any number of) tests in parallel.

For running on CI this can resolve the supported versions, outputting JSON that can then be used to run tests against the versions in parallel.

```bash
$ swift run swift-dependency-compatibility-checker --package-path ../HashableMacro/ swift-syntax --resolve-only

["509.1.0","509.1.1","510.0.0","510.0.1","510.0.2","510.0.3","600.0.0","600.0.1","601.0.0","601.0.1","602.0.0"]
```

```yml
jobs:
  generate_swift_syntax_version:
    name: Generate Swift Syntax Versions
    runs-on: macOS-latest
    outputs:
      matrix: ${{ steps.set-matrix.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4

      - run: brew install mint

      - name: Set up matrix
        id: set-matrix
        run: |
          matrix="$(mint run josephduffy/swift-dependency-compatibility-checker swift-syntax --resolve-only --github-actions-matrix)"
          echo "${matrix}"
          echo "matrix=${matrix}" >> "${GITHUB_OUTPUT}"

  test_swift_syntax_versions:
    name: Swift Syntax ${{ matrix.version }} Tests
    needs:
      - generate_swift_syntax_version
    runs-on: macOS-latest
    strategy:
      fail-fast: false
      matrix: ${{ fromJson(needs.generate_swift_syntax_version.outputs.matrix) }}

    steps:
      - uses: actions/checkout@v4

      - run: swift package resolve swift-syntax --version ${{ matrix.version }}

      - run: swift test | mint run xcbeautify --renderer github-actions
```

> ![NOTE]
> This is a _minimal_ setup. It does not include things like dependency caching.

## Inspiration

[I have wanted something like this for a while](https://forums.swift.org/t/force-installing-oldest-supported-version-of-a-dependency/76389). [I'm not the only one](https://forums.swift.org/t/how-to-iterate-through-set-of-exact-dependency-versions-for-swift-package-using-command-line/73608).

I happened to come across that second post recently, which has [a reply](https://forums.swift.org/t/how-to-iterate-through-set-of-exact-dependency-versions-for-swift-package-using-command-line/73608/2) that links to [Swift Macro Compatibility Check](https://github.com/Matejkob/swift-macro-compatibility-check). This package is good, but requires maintenance that I cannot and do not want to perform.

This is this first project with any real TUI I have worked on, so I also took some inspiration from [indicatif](https://github.com/console-rs/indicatif) for the progress style. I would like to learn and understand this more.

## Future Direction

This was a quick proof of concept for me to allow me to more easily maintain my macros. I would be happy to see the API improve and have it cover more use cases (e.g. a more restrictive or inclusive ruleset for the included versions).
