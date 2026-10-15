import Foundation

struct FileNameHelper {
    // Escape shell-sensitive characters in filenames
    static func escapeForShell(_ filename: String) -> String {
        // Characters that need escaping in shell commands
        let specialChars = CharacterSet(charactersIn: "\\\"'`$!&*()[]{};<>|?~ \t\n")
        
        var escaped = ""
        for char in filename {
            if char.unicodeScalars.first.map(specialChars.contains) == true {
                escaped.append("\\")
            }
            escaped.append(char)
        }
        
        return escaped
    }
    
    /// Escapes a string for safe use inside single quotes in a shell command.
    ///
    /// Inside single quotes, the ONLY character that needs special handling is `'` itself.
    /// The idiom `'\''` ends the current quote, inserts a literal `'`, and reopens the quote.
    /// International/Unicode characters pass through safely — single quotes preserve them as-is.
    static func escapeForSingleQuotedShell(_ value: String) -> String {
        return value.replacingOccurrences(of: "'", with: "'\\''")
    }
    
    // Sanitize filename by replacing problematic characters
    static func sanitizeFilename(_ filename: String, replacement: String = "_") -> String {
        // Replace characters that cause issues on Android
        let problematicChars = CharacterSet(charactersIn: "<>:\"|?*\\")
        
        var sanitized = ""
        for char in filename {
            if char.unicodeScalars.first.map(problematicChars.contains) == true {
                sanitized.append(replacement)
            } else {
                sanitized.append(char)
            }
        }
        
        // Also replace "->" which is interpreted as redirect operator
        sanitized = sanitized.replacingOccurrences(of: "->", with: "_to_")
        sanitized = sanitized.replacingOccurrences(of: ">>", with: "_append_")
        
        return sanitized
    }
    
    // Get safe version with original extension preserved
    static func getSafeFilename(_ filename: String) -> (safe: String, wasModified: Bool) {
        let sanitized = sanitizeFilename(filename)
        return (sanitized, sanitized != filename)
    }
}
