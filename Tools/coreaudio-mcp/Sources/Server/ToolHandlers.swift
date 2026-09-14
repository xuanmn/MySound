import Foundation

public struct ToolHandlers: Sendable {

    // =========================================================================
    // MARK: - Tool 1: search_apis
    // =========================================================================
    public static func handleSearchApis(arguments: [String: Any]) -> CallToolResult {
        guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .text("Error: Missing or empty 'query' parameter.", isError: true)
        }

        let cleanQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        let frameworkFilter = (arguments["framework"] as? String)?.lowercased()
        let onlySpi = (arguments["only_spi"] as? Bool) ?? false

        let results = CoreAudioRegistry.allEntities.filter { entity in
            if onlySpi && !entity.isPrivateSPI {
                return false
            }
            if let framework = frameworkFilter, !entity.framework.lowercased().contains(framework) {
                return false
            }

            let matchesSymbol = entity.symbol.lowercased().contains(cleanQuery)
            let matchesSummary = entity.summary.lowercased().contains(cleanQuery)
            let matchesHeader = entity.header.lowercased().contains(cleanQuery)
            let matchesRelated = entity.relatedSymbols.contains { $0.lowercased().contains(cleanQuery) }

            return matchesSymbol || matchesSummary || matchesHeader || matchesRelated
        }

        if results.isEmpty {
            return .text("No CoreAudio APIs found matching query '\(query)'.\nTry searching for broader terms like 'tap', 'aggregate', 'device', 'vDSP', or 'property'.")
        }

        var output = "### CoreAudio API Search Results for '\(query)' (\(results.count) match\(results.count == 1 ? "" : "es")):\n\n"
        output += "| Symbol | Kind | Framework | SPI? | Availability | Summary |\n"
        output += "| :--- | :--- | :--- | :---: | :--- | :--- |\n"

        for item in results {
            let spiBadge = item.isPrivateSPI ? "🔒 **Yes**" : "Public"
            output += "| `\(item.symbol)` | \(item.kind.rawValue) | \(item.framework) | \(spiBadge) | \(item.availability) | \(item.summary) |\n"
        }

        output += "\n> Use `get_api_details(symbol: \"<symbol>\")` to view the full specification, parameters, and real-time safety rules."
        return .text(output)
    }

    // =========================================================================
    // MARK: - Tool 2: get_api_details
    // =========================================================================
    public static func handleGetApiDetails(arguments: [String: Any]) -> CallToolResult {
        guard let symbol = arguments["symbol"] as? String, !symbol.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .text("Error: Missing or empty 'symbol' parameter.", isError: true)
        }

        let cleanSymbol = symbol.trimmingCharacters(in: .whitespaces)
        let exactMatch = CoreAudioRegistry.allEntities.first {
            $0.symbol.caseInsensitiveCompare(cleanSymbol) == .orderedSame
        }

        guard let entity = exactMatch ?? CoreAudioRegistry.allEntities.first(where: { $0.symbol.lowercased().contains(cleanSymbol.lowercased()) }) else {
            return .text("Error: API symbol '\(symbol)' not found in CoreAudio registry.\nUse `search_apis` to find valid symbols.", isError: true)
        }

        var md = "# API Reference: `\(entity.symbol)`\n\n"
        md += "- **Kind**: \(entity.kind.rawValue)\n"
        md += "- **Framework**: \(entity.framework)\n"
        md += "- **Header**: `\(entity.header)`\n"
        md += "- **Availability**: \(entity.availability)\n"
        md += "- **Access Level**: \(entity.isPrivateSPI ? "🔒 Private SPI (Undocumented)" : "Public Apple SDK API")\n\n"

        md += "## Summary\n\(entity.summary)\n\n"

        md += "## Signature\n```swift\n\(entity.signature)\n```\n\n"

        if !entity.parameters.isEmpty {
            md += "## Parameters\n"
            for param in entity.parameters {
                md += "- **`\(param.name)`** (`\(param.type)`): \(param.description)\n"
            }
            md += "\n"
        }

        md += "## Return Information\n\(entity.returnInfo)\n\n"

        if !entity.requiredEntitlements.isEmpty {
            md += "## Required Entitlements & Permissions\n"
            for ent in entity.requiredEntitlements {
                md += "- `\(ent)`\n"
            }
            md += "\n"
        }

        md += "## Real-Time Audio Safety Assessment\n"
        md += "> \(entity.realTimeSafety)\n\n"

        if !entity.commonPitfalls.isEmpty {
            md += "## Known Pitfalls & Gotchas\n"
            for pit in entity.commonPitfalls {
                md += "- ⚠️ \(pit)\n"
            }
            md += "\n"
        }

        if !entity.relatedSymbols.isEmpty {
            md += "## Related Symbols\n"
            for rel in entity.relatedSymbols {
                md += "- `\(rel)`\n"
            }
            md += "\n"
        }

        return .text(md)
    }

    // =========================================================================
    // MARK: - Tool 3: get_code_recipe
    // =========================================================================
    public static func handleGetCodeRecipe(arguments: [String: Any]) -> CallToolResult {
        if let recipeId = arguments["recipe_id"] as? String, !recipeId.trimmingCharacters(in: .whitespaces).isEmpty {
            let cleanId = recipeId.trimmingCharacters(in: .whitespaces).lowercased()
            guard let recipe = RecipesRegistry.allRecipes.first(where: { $0.id.lowercased() == cleanId || $0.id.lowercased().contains(cleanId) }) else {
                return .text("Error: Recipe with ID '\(recipeId)' not found. Available recipes: \(RecipesRegistry.allRecipes.map { $0.id }.joined(separator: ", "))", isError: true)
            }

            var md = "# Code Recipe: \(recipe.title)\n\n"
            md += "- **ID**: `\(recipe.id)`\n"
            md += "- **Category**: \(recipe.category)\n"
            md += "- **Summary**: \(recipe.summary)\n\n"

            md += "## Swift Implementation\n```swift\n\(recipe.code)\n```\n\n"

            md += "## Critical Takeaways & Invariants\n"
            for item in recipe.keyTakeaways {
                md += "- ✅ \(item)\n"
            }

            return .text(md)
        }

        // Return catalog of all recipes
        var list = "# CoreAudio Production Code Recipes Catalog\n\n"
        list += "Select a recipe by providing `recipe_id` parameter to `get_code_recipe`:\n\n"
        list += "| Recipe ID | Title | Category | Summary |\n"
        list += "| :--- | :--- | :--- | :--- |\n"

        for r in RecipesRegistry.allRecipes {
            list += "| `\(r.id)` | **\(r.title)** | \(r.category) | \(r.summary) |\n"
        }

        return .text(list)
    }

    // =========================================================================
    // MARK: - Tool 4: check_realtime_safety
    // =========================================================================
    public static func handleCheckRealtimeSafety(arguments: [String: Any]) -> CallToolResult {
        guard let code = arguments["code"] as? String, !code.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .text("Error: Missing or empty 'code' parameter to audit.", isError: true)
        }

        let lines = code.components(separatedBy: .newlines)
        var violations: [(lineNum: Int, lineText: String, rule: SafetyRule)] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") {
                continue
            }

            for rule in SafetyRegistry.allRules {
                for pattern in rule.patterns {
                    if trimmed.contains(pattern) {
                        violations.append((lineNum: index + 1, lineText: trimmed, rule: rule))
                        break
                    }
                }
            }
        }

        var report = "# Real-Time Audio Callback Safety Audit\n\n"

        if violations.isEmpty {
            report += "✅ **PASSED AUDIT**: No real-time audio anti-patterns detected.\n\n"
            report += "- No dynamic heap allocations (`malloc`, `Array`, `String`)\n"
            report += "- No Swift Concurrency async context hops (`Task`, `await`)\n"
            report += "- No coarse/blocking dispatch locks (`sync`, `NSLock`)\n"
            report += "- No dynamic Objective-C messaging overhead\n\n"
            report += "> Note: Always ensure buffer sizes are bound to `inNumberFrames` and pointer offsets are validated."
            return .text(report)
        }

        let errorCount = violations.filter { $0.rule.severity == .error }.count
        let warningCount = violations.filter { $0.rule.severity == .warning }.count

        report += "❌ **VIOLATIONS DETECTED**: Found **\(errorCount) Error(s)** and **\(warningCount) Warning(s)**.\n\n"
        report += "Code executing inside an audio IO proc runs on a high-priority, non-preemptible real-time thread. The following lines will cause audio glitches, under-runs, or watchdog termination:\n\n"

        report += "| Line | Severity | Violation | Code Snippet |\n"
        report += "| :---: | :---: | :--- | :--- |\n"

        for v in violations {
            let badge = v.rule.severity == .error ? "🔴 **ERROR**" : "🟡 **WARN**"
            report += "| Line \(v.lineNum) | \(badge) | **\(v.rule.name)** | `\(v.lineText)` |\n"
        }

        report += "\n## Remediation Guidelines\n\n"
        let triggeredRules = Array(Set(violations.map { $0.rule.id }))

        for ruleId in triggeredRules {
            guard let rule = SafetyRegistry.allRules.first(where: { $0.id == ruleId }) else { continue }
            report += "### \(rule.name)\n"
            report += "- **Why it fails**: \(rule.explanation)\n"
            report += "- **How to fix**: \(rule.remedy)\n\n"
        }

        return .text(report)
    }
}
