import Foundation

/// The sudoers drop-in that lets Lidless toggle `disablesleep` without a password prompt.
/// It grants one user two fixed commands and nothing else.
public enum SudoersRule {
    public static let path = "/private/etc/sudoers.d/lidless"
    /// sudo skips files in sudoers.d whose name contains a dot, so a half-written rule is inert.
    static let stagingPath = "/private/etc/sudoers.d/.lidless.tmp"

    static let commands = [
        "/usr/bin/pmset -a disablesleep 0",
        "/usr/bin/pmset -a disablesleep 1",
    ]

    public static func contents(user: String, uid: UInt32) -> String {
        var lines = [
            "# Installed by Lidless (https://github.com/Benabens/lidless).",
            "# Lets one user turn closed-lid sleep off and back on without a password. Nothing else.",
        ]
        var principal = user
        if !isPlainUserName(user) {
            // Fall back to the numeric ID. Behind an alias, because a line that starts with
            // "#501" is too easy to mistake for a comment.
            lines.append("User_Alias LIDLESS_USER = #\(uid)")
            principal = "LIDLESS_USER"
        }
        lines.append("\(principal) ALL=(root) NOPASSWD: \(commands.joined(separator: ", "))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether `user` can be written into a sudoers file as is, with no way to alter the rule.
    private static func isPlainUserName(_ user: String) -> Bool {
        let first = Set("abcdefghijklmnopqrstuvwxyz_")
        let rest = first.union("0123456789.-")
        guard let head = user.first, user.count <= 64 else { return false }
        return first.contains(head) && user.allSatisfy(rest.contains)
    }

    /// To be run as root. The rule is written by root into a root-owned directory and checked by
    /// visudo before it is moved into place, so a bad rule can never lock sudo up.
    public static func installScript(user: String, uid: UInt32) -> String {
        let lines = contents(user: user, uid: uid)
            .split(separator: "\n")
            .map { String($0).shellQuoted }
            .joined(separator: " ")
        return [
            "set -e",
            "umask 077",
            "/bin/mkdir -p /private/etc/sudoers.d",
            "/usr/bin/printf '%s\\n' \(lines) > \(stagingPath)",
            "/usr/sbin/chown root:wheel \(stagingPath)",
            "/bin/chmod 0440 \(stagingPath)",
            "if /usr/sbin/visudo -cf \(stagingPath) >/dev/null; then /bin/mv -f \(stagingPath) \(path); "
                + "else /bin/rm -f \(stagingPath); exit 1; fi",
        ].joined(separator: "\n")
    }

    public static let uninstallScript = "/bin/rm -f \(path)"

    /// AppleScript that runs `shell` as root after the standard administrator prompt.
    public static func appleScript(running shell: String, prompt: String) -> String {
        func quoted(_ string: String) -> String {
            "\"" + string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "do shell script \(quoted(shell)) with prompt \(quoted(prompt)) with administrator privileges"
    }
}
