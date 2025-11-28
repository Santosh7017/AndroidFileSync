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
