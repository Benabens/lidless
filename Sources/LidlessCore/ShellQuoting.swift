extension String {
    /// This string as a single word for `sh`, whatever it contains.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
