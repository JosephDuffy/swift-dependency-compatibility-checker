import ArgumentParser
import Foundation
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
        print(dependency)

        let range: SourceControlPackageDependencyRequirementRange =
            switch dependency.requirement {
            case .branch(let branch):
                print("Dependency is pinned to a branch; no range to test.")
                throw ExitCode(1)
            case .exact(let exact):
                print("Dependency is pinned to a branch; no range to test.")
                throw ExitCode(1)
            case .range(let range):
                range
            }

        print(range)

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
        let matchingTags = gitTagsOutput
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

        for matchingTag in matchingTags {
            let temporaryDirectory = FileManager.default.temporaryDirectory.appending(
                path: packageDescription.name + "-" + ProcessInfo.processInfo.globallyUniqueString,
                directoryHint: .isDirectory
            )
            if FileManager.default.fileExists(atPath: temporaryDirectory.path()) {
                print("Directory exists at", temporaryDirectory.path(), ". Deleting before copying.")
                try FileManager.default.removeItem(at: temporaryDirectory)
            }
            print("Copying package to", temporaryDirectory.path())
            try FileManager.default.copyItem(
                at: URL(filePath: packagePath ?? "./"),
                to: temporaryDirectory
            )

            defer {
                print("Deleting temporary copy of package from", temporaryDirectory.path())
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }

            let buildDirectory = temporaryDirectory.appending(path: ".build", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: buildDirectory.path()) {
                print("There's an existing .build directory at", buildDirectory.path(), ". Removing.")
                try FileManager.default.removeItem(at: buildDirectory)
            }

            print("Resolving existing dependencies to enable resolving to a specific version.")
            let resolveAllResult = try await Subprocess.run(
                .name("swift"),
                arguments: [
                    "package",
                    "--package-path", temporaryDirectory.path(),
                    "resolve",
                ],
                output: .standardOutput,
                error: .standardError
            )

            guard resolveAllResult.terminationStatus.isSuccess else {
                throw ExitCode(1)
            }

            print("Resolving", dependencyName, "to", matchingTag)
            let resolveResult = try await Subprocess.run(
                .name("swift"),
                arguments: [
                    "package",
                    "--package-path", temporaryDirectory.path(),
                    "resolve",
                    dependencyName,
                    "--version", "\(matchingTag)",
                ],
                output: .standardOutput,
                error: .standardError
            )

            guard resolveResult.terminationStatus.isSuccess else {
                throw ExitCode(1)
            }

            let testResult = try await Subprocess.run(
                .name("swift"),
                arguments: [
                    "test",
                    "--package-path", temporaryDirectory.path(),
                ],
                output: .standardOutput,
                error: .standardError
            )

            guard resolveResult.terminationStatus.isSuccess else {
                print("Tests failed for", matchingTag)
                throw ExitCode(1)
            }
        }

        print("All tests passed!")
    }
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
