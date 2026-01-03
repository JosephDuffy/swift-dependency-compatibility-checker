import ArgumentParser
import Foundation
import OrderedCollections
import SemanticVersion
import Subprocess

@main
struct SwiftDependencyCompatibilityChecker: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            abstract: "Check if a Swift package is compatible with the declared range of a dependency..",
        )
    }

    @Argument(help: "The name of the dependency to test the range of.")
    public var dependencyName: String

    @Option(help: "The path to the package being tested. Defaults to working directory.")
    public var packagePath: String?

    @Option(help: "The number of tests to run in parallel.")
    public var numTests = 1

    @Flag
    public var resolveOnly = false

    @Flag(name: .customLong("github-actions-matrix"))
    public var gitHubActionsMatrix = false

    @Flag(help: ArgumentHelp(visibility: .private))
    public var mockTesting = false

    public func run() async throws {
        var dumpPackageArguments = [
            "package",
            "dump-package",
        ]

        if let packagePath {
            dumpPackageArguments += [
                "--package-path", packagePath,
            ]
        }

        let swiftDumpPackageResult = try await Subprocess.run(
            .name("swift"),
            arguments: Arguments(dumpPackageArguments),
            output: .string(limit: 128 * 1024),
        )
        guard swiftDumpPackageResult.terminationStatus.isSuccess, let packageDumpOutput = swiftDumpPackageResult.standardOutput else {
            if let output = swiftDumpPackageResult.standardOutput {
                print(output)
            }
            print("Failed to determine root git directory")
            throw ExitCode(1)
        }

        let jsonDecoder = JSONDecoder()
        jsonDecoder.semanticVersionDecodingStrategy = .semverString
        let packageDescription: PackageDescription = try jsonDecoder.decode(
            PackageDescription.self,
            from: Data(packageDumpOutput.utf8)
        )

        guard
            let dependency = packageDescription
                .dependencies?
                .lazy
                .flatMap({ $0.sourceControl ?? [] })
                .first(where: { $0.identity == dependencyName })
        else {
            print("Couldn't find dependency")
            throw ExitCode(1)
        }

        let range: SourceControlPackageDependencyRequirementRange =
            switch dependency.requirement {
            case .branch(let branch):
                print("Dependency is pinned to '\(branch)' branch; no range to test.")
                throw ExitCode(1)
            case .exact(let exact):
                print("Dependency is pinned to '\(exact)'; no range to test.")
                throw ExitCode(1)
            case .range(let range):
                range
            }

        guard let remoteURL = dependency.location.remote else {
            print("No remote location for depenency")
            throw ExitCode(1)
        }

        let gitListTagsResult = try await Subprocess.run(
            .name("git"),
            arguments: [
                "ls-remote",
                "--tags",
                "--sort=version:refname",
                remoteURL,
            ],
            output: .string(limit: 1024 * 1024),
        )
        guard gitListTagsResult.terminationStatus.isSuccess, let gitTagsOutput = gitListTagsResult.standardOutput else {
            if let output = swiftDumpPackageResult.standardOutput {
                print(output)
            }
            print("Failed to determine remote git tags")
            throw ExitCode(1)
        }
        let matchingTags = OrderedSet(
            gitTagsOutput
                .components(separatedBy: .newlines)
                .lazy
                .compactMap { $0.split(separator: "\t", maxSplits: 1).last }
                .compactMap {
                    let prefix = "refs/tags/"
                    if $0.hasPrefix(prefix) {
                        return String($0.dropFirst(prefix.count))
                    } else {
                        return nil
                    }
                }
                .compactMap(SemanticVersion.init(_:))
                .filter { $0.isStable && range.lowerBound <= $0 && $0 < range.upperBound }
        )

        if resolveOnly {
            let jsonEncoder = JSONEncoder()
            jsonEncoder.semanticVersionEncodingStrategy = .semverString
            if gitHubActionsMatrix {
                let matrix = GitHubActionsMatrix(
                    include: matchingTags.map(GitHubActionsInclude.init(version:))
                )
                let encodedMatrix = try jsonEncoder.encode(matrix)
                print(String(data: encodedMatrix, encoding: .utf8)!)
            } else {
                let encodedTags = try jsonEncoder.encode(matchingTags)
                print(String(data: encodedTags, encoding: .utf8)!)
            }
            return
        }

        // TODO: It would be faster to copy to a temp directory, do the initial resolve, then keep some of the .build directory

        let progressTracker = ProgressTracker(versions: Array(matchingTags))
        await progressTracker.startActivityIndicator()

        #if swift(>=6.2)
        @concurrent
        func testVersion(_ matchingTag: SemanticVersion) async {
            await _testVersion(matchingTag)
        }
        #else
        nonisolated
        func testVersion(_ matchingTag: SemanticVersion) async {
            await _testVersion(matchingTag)
        }
        #endif
        func _testVersion(_ matchingTag: SemanticVersion) async {
            await progressTracker.inProgressVersion(matchingTag, latestMessage: nil)

            if mockTesting {
                try? await Task.sleep(for: .seconds(.random(in: 1 ... 5)))
                await progressTracker.passVersion(matchingTag)
                return
            }

            do {
                let temporaryDirectory = FileManager.default.temporaryDirectory.appending(
                    path: packageDescription.name + "-" + dependencyName + "-" + matchingTag.description + "-" + ProcessInfo.processInfo.globallyUniqueString,
                    directoryHint: .isDirectory
                )
                if FileManager.default.fileExists(atPath: temporaryDirectory.path()) {
                    await progressTracker.inProgressVersion(
                        matchingTag,
                        latestMessage: "Directory exists at \(temporaryDirectory.path()). Deleting before copying."
                    )
                    try FileManager.default.removeItem(at: temporaryDirectory)
                }
                await progressTracker.inProgressVersion(
                    matchingTag,
                    latestMessage: "Copying package to \(temporaryDirectory.path())"
                )
                try FileManager.default.copyItem(
                    at: URL(filePath: packagePath ?? "./"),
                    to: temporaryDirectory
                )

                defer {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }

                _ = try await Subprocess.run(
                    .name("swift"),
                    arguments: [
                        "package",
                        "--package-path", temporaryDirectory.path(),
                        "clean",
                    ]
                ) { execution, standardOutput in
                    for try await line in standardOutput.lines() {
                        await progressTracker.inProgressVersion(
                            matchingTag,
                            latestMessage: line
                        )
                    }
                }

                await progressTracker.inProgressVersion(
                    matchingTag,
                    latestMessage: "Resolving existing dependencies to enable resolving to a specific version."
                )
                let resolveAllResult = try await Subprocess.run(
                    .name("swift"),
                    arguments: [
                        "package",
                        "--package-path", temporaryDirectory.path(),
                        "resolve",
                    ]
                ) { execution, standardOutput in
                    for try await line in standardOutput.lines() {
                        await progressTracker.inProgressVersion(
                            matchingTag,
                            latestMessage: line
                        )
                    }
                }

                guard resolveAllResult.terminationStatus.isSuccess else {
                    throw ExitCode(1)
                }

                await progressTracker.inProgressVersion(
                    matchingTag,
                    latestMessage: "Resolving \(dependencyName) to \(matchingTag)"
                )
                let resolveResult = try await Subprocess.run(
                    .name("swift"),
                    arguments: [
                        "package",
                        "--package-path", temporaryDirectory.path(),
                        "resolve",
                        dependencyName,
                        "--version", "\(matchingTag)",
                    ]
                ) { execution, standardOutput in
                    for try await line in standardOutput.lines() {
                        await progressTracker.inProgressVersion(
                            matchingTag,
                            latestMessage: line
                        )
                    }
                }

                guard resolveResult.terminationStatus.isSuccess else {
                    throw ExitCode(1)
                }

                let testResult = try await Subprocess.run(
                    .name("swift"),
                    arguments: [
                        "test",
                        "--package-path", temporaryDirectory.path(),
                    ]
                ) { execution, standardOutput in
                    for try await line in standardOutput.lines() {
                        await progressTracker.inProgressVersion(
                            matchingTag,
                            latestMessage: line
                        )
                    }
                }

                guard testResult.terminationStatus.isSuccess else {
                    throw ExitCode(1)
                }

                await progressTracker.passVersion(matchingTag)
            } catch {
                await progressTracker.failVersion(matchingTag, reason: String(describing: error))
            }
        }

        if numTests > 1 {
            await withTaskGroup(of: Void.self) { taskGroup in
                let concurrentTasks = min(numTests, matchingTags.count)
                for index in 0 ..< concurrentTasks {
                    let matchingTag = matchingTags[index]
                    taskGroup.addTask {
                        await testVersion(matchingTag)
                    }
                }

                var nextIndex = concurrentTasks

                for await _ in taskGroup {
                    if nextIndex < matchingTags.count {
                        let matchingTag = matchingTags[nextIndex]
                        nextIndex += 1
                        taskGroup.addTask {
                            await testVersion(matchingTag)
                        }
                    }
                }
            }
        } else {
            for matchingTag in matchingTags {
                await testVersion(matchingTag)
            }
        }
    }
}

actor ProgressTracker {
    enum VersionStatus {
        case pending
        case inProgress(latestMessage: String?)
        case passed
        case failed(reason: String?)
    }

    private(set) var versions: OrderedDictionary<SemanticVersion, VersionStatus>

    private let progressCharacters = Array("⣷⣯⣟⡿⢿⣻⣽⣾")

//    private let progressCharacters = Array("|/-\\")

    private var progressCharacterIndex = 0

    private var animateActivityIndicatorTask: Task<Void, Error>?

    private var hasPrintedProgress = false

    init(versions: [SemanticVersion]) {
        self.versions = OrderedDictionary(uniqueKeysWithValues: zip(versions, repeatElement(.pending, count: versions.count)))
    }

    deinit {
        animateActivityIndicatorTask?.cancel()
    }

    func inProgressVersion(_ version: SemanticVersion, latestMessage: String?) {
        versions[version] = .inProgress(latestMessage: latestMessage)

        printProgress()
    }

    func passVersion(_ version: SemanticVersion) {
        versions[version] = .passed

        printProgress()
    }

    func failVersion(_ version: SemanticVersion, reason: String?) {
        versions[version] = .failed(reason: reason)

        printProgress()
    }

    func startActivityIndicator() {
        guard animateActivityIndicatorTask == nil else { return }

        animateActivityIndicatorTask = Task {
            while true {
                incrementProgress()
                try await Task.sleep(for: .seconds(0.2))
                try Task.checkCancellation()
            }
        }
    }

    func stopActivityIndicator() {
        animateActivityIndicatorTask?.cancel()
        animateActivityIndicatorTask = nil
    }

    private func printProgress() {
        var index = 0
        let statuses = versions.map { (version, status) in
            index += 1

            var statusString = "["
            statusString += String(
                repeating: " ",
                count: "\(versions.count)".count - "\(index)".count
            )
            statusString += "\(index)/\(versions.count)] \(progressCharacters[progressCharacterIndex]) \(version): "

            switch status {
            case .pending:
                statusString += "Pending..."
            case .inProgress(let latestMessage):
                statusString += latestMessage ?? "In progress..."
            case .failed(let reason):
                statusString += reason ?? "Failed."
            case .passed:
                statusString += "\u{1B}[0;92m􁁛\u{1B}[0m  Passed."
            }

            return statusString
        }

        var lines = statuses.joined(
            separator: "\n"
        )

        if hasPrintedProgress {
            let clearLine = "\u{1B}[1A\u{1B}[K"
            lines = repeatElement(clearLine, count: statuses.count).joined() + lines
        } else {
            hasPrintedProgress = true
        }

        print(lines)
    }

    private func incrementProgress() {
        if progressCharacters.index(after: progressCharacterIndex) == progressCharacters.endIndex {
            progressCharacterIndex = 0
        } else {
            progressCharacterIndex = progressCharacters.index(after: progressCharacterIndex)
        }

        printProgress()
    }
}

struct GitHubActionsMatrix: Encodable {
    let include: [GitHubActionsInclude]
}

struct GitHubActionsInclude: Encodable {
    let version: SemanticVersion
}

struct PackageDescription: Decodable {
    let name: String
    let dependencies: [PackageDependency]?
}

struct PackageDependency: Decodable {
    /// Could also be `fileSystem` for local dependencies, which we ignore.
    let sourceControl: [SourceControlPackageDependency]?
}

struct SourceControlPackageDependency: Decodable {
    let identity: String
    let location: SourceControlPackageDependencyLocation
    let requirement: SourceControlPackageDependencyRequirement
}

struct SourceControlPackageDependencyLocation: Decodable {
    let remote: String?

    enum CodingKeys: CodingKey {
        case remote
    }

    init(from decoder: any Decoder) throws {
        struct RemoteLocation: Decodable {
            let urlString: String
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let remoteLocations = try container.decodeIfPresent([RemoteLocation].self, forKey: .remote) else {
            remote = nil
            return
        }
        guard let remoteLocation = remoteLocations.first else {
            fatalError()
        }
        remote = remoteLocation.urlString
    }
}

enum SourceControlPackageDependencyRequirement: Decodable {
    case range(SourceControlPackageDependencyRequirementRange)
    case exact(String)
    case branch(String)

    enum CodingKeys: CodingKey {
        case range
        case exact
        case branch
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var allKeys = ArraySlice(container.allKeys)
        guard let onlyKey = allKeys.popFirst(), allKeys.isEmpty else {
            throw DecodingError
                .typeMismatch(
                    SourceControlPackageDependencyRequirement.self,
                    DecodingError.Context.init(
                        codingPath: container.codingPath,
                        debugDescription: "Invalid number of keys found, expected one.",
                        underlyingError: nil
                    )
                )
        }
        switch onlyKey {
        case .range:
            let ranges = try container.decode([SourceControlPackageDependencyRequirementRange].self, forKey: onlyKey)
            guard let range = ranges.first else {
                fatalError()
            }
            self = .range(range)
        case .exact:
            let ranges = try container.decode([String].self, forKey: onlyKey)
            guard let range = ranges.first else {
                fatalError()
            }
            self = .exact(range)
        case .branch:
            let branches = try container.decode([String].self, forKey: onlyKey)
            guard let branch = branches.first else {
                fatalError()
            }
            self = .branch(branch)
        }
    }
}

struct SourceControlPackageDependencyRequirementRange: Decodable {
    let lowerBound: SemanticVersion
    let upperBound: SemanticVersion
}
