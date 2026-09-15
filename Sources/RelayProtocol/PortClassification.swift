import Foundation

/// Tells development ports from the rest of what a Mac happens to be listening
/// on.
///
/// An unfiltered list is mostly macOS: Control Centre, AirPlay, Handoff,
/// Spotlight and a dozen background agents. The port you came to look for is
/// buried in it. Classification is deliberately generous — a false positive
/// costs one extra row, a false negative hides the thing you were looking for.
public enum PortClassification {
    /// Runtimes, build tools, databases and brokers that only appear in a
    /// development context.
    private static let developmentProcesses: Set<String> = [
        "node", "deno", "bun", "npm", "pnpm", "yarn", "vite", "esbuild", "webpack", "turbo", "next-server",
        "python", "python3", "uvicorn", "gunicorn", "flask", "django",
        "ruby", "rails", "puma", "unicorn", "sidekiq",
        "java", "gradle", "kotlin", "sbt", "scala",
        "php", "php-fpm", "artisan", "composer",
        "go", "air", "dotnet", "cargo", "rustc", "swift", "xcodebuild",
        "elixir", "beam.smp", "erl", "dart", "flutter",
        "postgres", "postmaster", "mysqld", "mariadbd", "redis-server", "mongod", "memcached",
        "elasticsearch", "opensearch", "rabbitmq", "nats-server", "kafka", "zookeeper",
        "nginx", "httpd", "caddy", "traefik", "envoy",
        "docker", "dockerd", "containerd", "com.docker.backend", "qemu-system-aarch64",
        "adb", "ngrok", "cloudflared", "localtunnel",
    ]

    /// Ports the platform itself owns. Control Centre alone answers on two of
    /// the most development-looking numbers there are.
    private static let systemProcesses: Set<String> = [
        "ControlCenter", "rapportd", "sharingd", "identityservicesd", "remoted", "launchd",
        "mDNSResponder", "CommCenter", "Spotlight", "bird", "cloudd", "UserEventAgent",
        "AirPlayXPCHelper", "sshd", "netbiosd", "SubmitDiagInfo", "rmd", "TelemetryDaemon",
    ]

    /// Ranges a development server is conventionally reached on.
    private static let developmentRanges: [ClosedRange<Int>] = [
        1_234 ... 1_234,
        3_000 ... 3_999,
        4_000 ... 4_999,
        5_100 ... 5_999,
        7_100 ... 7_999,
        8_000 ... 8_999,
        9_000 ... 9_999,
        19_000 ... 19_999,
        24_678 ... 24_678,
    ]

    /// Well-known service ports that are development infrastructure far more
    /// often than not.
    private static let developmentPorts: Set<Int> = [
        5_432, 3_306, 6_379, 27_017, 9_200, 5_672, 15_672, 11_211, 1_433, 5_601, 8_025, 1_025,
    ]

    public static func isDevelopment(_ port: ListeningPort) -> Bool {
        // Anything Relay started is the user's own work by definition.
        if port.isManagedByRelay { return true }

        let process = port.processName
        if systemProcesses.contains(process) { return false }
        if developmentProcesses.contains(process) { return true }
        if developmentPorts.contains(port.port) { return true }

        // A generous net for the rest: an unrecognised process on a development
        // port is far more likely to be worth showing than to be noise.
        return developmentRanges.contains { $0.contains(port.port) }
    }
}
