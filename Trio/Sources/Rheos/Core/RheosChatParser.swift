import Foundation

struct RheosChatSuggestion: Equatable, Identifiable {
    var id: String { "\(kind)-\(text)" }
    var kind: String
    var text: String
}

enum RheosChatParser {
    /// Pulls optional suggestion blocks out of a reply.
    /// A suggestion is a note the user can confirm. It is not a dose and not a limit change.
    static func suggestions(in reply: String) -> [RheosChatSuggestion] {
        let pattern = #"\[\[suggestion kind=([a-z]+)\]\]([\s\S]*?)\[\[/suggestion\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(reply.startIndex..., in: reply)
        return regex.matches(in: reply, range: range).compactMap { match in
            guard let kindRange = Range(match.range(at: 1), in: reply),
                  let textRange = Range(match.range(at: 2), in: reply) else { return nil }
            let kind = String(reply[kindRange])
            guard ["sport", "urlaub", "krank", "fasten", "showtime", "meal"].contains(kind) else { return nil }
            let text = reply[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RheosChatSuggestion(kind: kind, text: text)
        }
    }

    static func instructions() -> String {
        """
        Du erklärst den Rheos-Schattenbericht dieser einen Person. Antworte in der Sprache der Frage.
        Du darfst Muster beschreiben und optionale Hinweise geben.
        Du darfst keinen Bolus, keine Basalrate und keine Änderung von Max IOB, Max Basal, Max Bolus, Max SMB oder Autosens anordnen.
        Wenn du einen freiwilligen Hinweis gibst, schreibe ihn genau so:
        [[suggestion kind=sport]]
        kurzer Text
        [[/suggestion]]
        Erlaubte kind-Werte: sport, urlaub, krank, fasten, showtime, meal.
        Ein Hinweis wird erst nach einer Bestätigung in der App notiert und dosiert nie.
        """
    }
}

/// Read-only data tools for the cloud chat (OpenAI-compatible function calling). Each tool reads
/// the Rheos dataset on this iPhone and returns a short text table. None of them doses, writes a
/// setting or reaches a device; the model can only look.
enum RheosChatTools {
    static let guidance = """
    Du hast Werkzeuge, die echte Daten dieser Person auf dem iPhone lesen: glucose_by_hour, day_summary, \
    meal_outcomes, learned_factors, delivered_basal, activity, recovery, pilot. Rufe sie auf, bevor du über Muster, Tage, \
    Mahlzeiten oder Einstellungen sprichst, und nenne die Zahlen daraus. Erfinde keine Werte. Die Werkzeuge \
    lesen nur. Sie dosieren nicht und ändern keine Einstellung.
    """

    static var definitions: [[String: Any]] {
        [
            function(
                "glucose_by_hour",
                "Median glucose, time in range 70–180 mg/dL, share below 70 and number of values per clock hour over the last days.",
                properties: ["days": integer("Days back, 1 to 45. Default 14.")]
            ),
            function(
                "day_summary",
                "One day: glucose mean, min, max, time in range, values below 70; bolus, SMB and basal insulin; carbs, fat and protein.",
                properties: ["date": text("Day as YYYY-MM-DD in local time. Default today.")]
            ),
            function(
                "meal_outcomes",
                "Meals of the last days: time, carbs, fat, protein, meal bolus, SMB in the next 3 hours, glucose before, after 2 and after 4 hours.",
                properties: ["days": integer("Days back, 1 to 30. Default 7.")]
            ),
            function(
                "learned_factors",
                "Rheos per clock hour: learned and applied basal, ISF and carb-ratio multipliers, the band, the mode and the walk-forward check.",
                properties: [:]
            ),
            function(
                "delivered_basal",
                "Per clock hour: insulin the pump delivered in quiet fasting hours divided by the scheduled basal (1.0 means the schedule fits).",
                properties: [:]
            ),
            function(
                "activity",
                "Workouts and sleep from Apple Health over the last days.",
                properties: ["days": integer("Days back, 1 to 30. Default 7.")]
            ),
            function(
                "pilot",
                "The Rheos Pilot shadow report: how an own dosing rule would have decided on the stored loops compared with oref and with what happened, and whether Trio's ISF or the Rheos-learned ISF predicted better.",
                properties: [:]
            ),
            function(
                "recovery",
                "Recovery score per day (0–100 from HRV, resting heart rate and sleep against the person's own 30 days) and what Rheos learned about how recovery moves this person's insulin need.",
                properties: ["days": integer("Days back, 1 to 45. Default 14.")]
            )
        ]
    }

    private static func function(_ name: String, _ description: String, properties: [String: Any]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": ["type": "object", "properties": properties]
            ]
        ]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func text(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    static func run(
        name: String,
        arguments: String,
        dataset: RheosDataset,
        decision: RheosProfileDecision?,
        scheduledBasal: [Double],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let parsed = arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let args = parsed as? [String: Any] ?? [:]
        func days(_ fallback: Int, _ limit: Int) -> Int {
            let number = (args["days"] as? NSNumber)?.intValue ?? Int(args["days"] as? String ?? "") ?? fallback
            return min(max(number, 1), limit)
        }
        switch name {
        case "glucose_by_hour":
            return glucoseByHour(dataset, days: days(14, 45), now: now, calendar: calendar)
        case "day_summary":
            return daySummary(dataset, date: args["date"] as? String, now: now, calendar: calendar)
        case "meal_outcomes":
            return mealOutcomes(dataset, days: days(7, 30), now: now, calendar: calendar)
        case "learned_factors":
            return learnedFactors(decision)
        case "delivered_basal":
            return deliveredBasal(dataset, scheduledBasal: scheduledBasal, calendar: calendar)
        case "activity":
            return activity(dataset, days: days(7, 30), now: now, calendar: calendar)
        case "recovery":
            return recovery(dataset, days: days(14, 45), scheduledBasal: scheduledBasal, now: now, calendar: calendar)
        case "pilot":
            return RheosPilot.load()?.lines.joined(separator: "\n") ?? "Noch kein Pilot-Bericht. Er entsteht bei der nächsten Rheos-Auswertung."
        default:
            return "Unbekanntes Werkzeug \(name)."
        }
    }

    static func glucoseByHour(_ dataset: RheosDataset, days: Int, now: Date, calendar: Calendar) -> String {
        let start = now.addingTimeInterval(-Double(days) * 86400)
        let points = dataset.glucose.filter { $0.date >= start && $0.date <= now && $0.mgdl > 0 }
        guard !points.isEmpty else { return "Keine Glukosewerte in den letzten \(days) Tagen." }
        var byHour = [[Double]](repeating: [], count: 24)
        for point in points {
            byHour[calendar.component(.hour, from: point.date)].append(point.mgdl)
        }
        var lines = ["Letzte \(days) Tage. Stunde | Median mg/dL | 70–180 | unter 70 | Werte"]
        for hour in 0 ..< 24 {
            let values = byHour[hour]
            guard !values.isEmpty, let median = RheosStats.median(values) else { continue }
            let inRange = percent(values.filter { $0 >= 70 && $0 <= 180 }.count, of: values.count)
            let low = percent(values.filter { $0 < 70 }.count, of: values.count)
            lines.append(String(format: "%02d | %.0f | %.0f %% | %.0f %% | %d", hour, median, inRange, low, values.count))
        }
        return lines.joined(separator: "\n")
    }

    static func daySummary(_ dataset: RheosDataset, date: String?, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = calendar.startOfDay(for: date.flatMap { formatter.date(from: $0) } ?? now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let label = formatter.string(from: start)
        let values = dataset.glucose.filter { $0.date >= start && $0.date < end && $0.mgdl > 0 }.map(\.mgdl)
        var lines = ["Tag \(label)."]
        if let mean = RheosStats.mean(values), let low = values.min(), let high = values.max() {
            lines.append(String(
                format: "Glukose: Mittel %.0f, tiefster %.0f, höchster %.0f mg/dL, 70–180 %.0f %%, unter 70 %.0f %%, %d Werte.",
                mean, low, high,
                percent(values.filter { $0 >= 70 && $0 <= 180 }.count, of: values.count),
                percent(values.filter { $0 < 70 }.count, of: values.count),
                values.count
            ))
        } else {
            lines.append("Keine Glukosewerte an diesem Tag.")
        }
        let insulin = dataset.insulin.filter { $0.date >= start && $0.date < end }
        func units(_ kind: String) -> Double {
            insulin.filter { $0.kind == kind }.reduce(0) { $0 + $1.units }
        }
        lines.append(String(
            format: "Insulin: Bolus %.2f U, SMB %.2f U, Temp-Basal %.2f U, geplantes Basal laut Pumpe %.2f U.",
            units("bolus"), units("smb"), units("tempBasal"), units("scheduledBasal")
        ))
        let meals = dataset.meals.filter { $0.date >= start && $0.date < end }
        lines.append(String(
            format: "Mahlzeiten: %d, Kohlenhydrate %.0f g, Fett %.0f g, Eiweiß %.0f g.",
            meals.count,
            meals.reduce(0) { $0 + $1.carbs },
            meals.reduce(0) { $0 + $1.fat },
            meals.reduce(0) { $0 + $1.protein }
        ))
        return lines.joined(separator: "\n")
    }

    static func mealOutcomes(_ dataset: RheosDataset, days: Int, now: Date, calendar: Calendar) -> String {
        let start = now.addingTimeInterval(-Double(days) * 86400)
        let meals = dataset.meals
            .filter { $0.date >= start && $0.date <= now && ($0.carbs > 0 || $0.fat + $0.protein > 0) }
            .sorted { $0.date > $1.date }
            .prefix(25)
        guard !meals.isEmpty else { return "Keine Mahlzeiten in den letzten \(days) Tagen." }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "EE dd.MM. HH:mm"
        func glucose(_ date: Date) -> String {
            RheosMealDelta.sample(dataset.glucose, at: date).map { String(format: "%.0f", $0) } ?? "–"
        }
        var lines = ["Zeit | KH/Fett/Eiweiß g | Bolus U | SMB 3 h U | Glukose vorher → 2 h → 4 h"]
        for meal in meals {
            let bolus = dataset.insulin.filter {
                $0.kind == "bolus" && abs($0.date.timeIntervalSince(meal.date)) <= 20 * 60
            }.reduce(0) { $0 + $1.units }
            let smb = dataset.insulin.filter {
                $0.kind == "smb" && $0.date >= meal.date.addingTimeInterval(-20 * 60) && $0.date <= meal.date.addingTimeInterval(3 * 3600)
            }.reduce(0) { $0 + $1.units }
            lines.append(String(
                format: "%@ | %.0f/%.0f/%.0f | %.2f | %.2f | %@ → %@ → %@",
                formatter.string(from: meal.date), meal.carbs, meal.fat, meal.protein, bolus, smb,
                glucose(meal.date), glucose(meal.date.addingTimeInterval(2 * 3600)), glucose(meal.date.addingTimeInterval(4 * 3600))
            ))
        }
        return lines.joined(separator: "\n")
    }

    static func learnedFactors(_ decision: RheosProfileDecision?) -> String {
        guard let decision else { return "Noch keine Rheos-Auswertung." }
        var lines = [
            "Modus \(decision.mode.rawValue), angewendet: \(decision.applied ? "ja" : "nein"), Band \(String(format: "%.2f–%.2f", decision.bandMinimum, decision.bandMaximum)).",
            "Prüfung: \(decision.walkForward.reason)",
            "Faktor über 1 bei Basal heißt mehr Basal, unter 1 bei ISF und KH-Faktor heißt mehr Insulin.",
            "Stunde | Basal gelernt/angewendet | ISF gelernt/angewendet | KH gelernt/angewendet"
        ]
        let learned = decision.learnedFactors
        let applied = decision.factors
        guard learned.basal.count == 24, learned.isf.count == 24, learned.carbRatio.count == 24,
              applied.basal.count == 24, applied.isf.count == 24, applied.carbRatio.count == 24
        else { return lines.joined(separator: "\n") }
        for hour in 0 ..< 24 {
            lines.append(String(
                format: "%02d | %.2f/%.2f | %.2f/%.2f | %.2f/%.2f",
                hour,
                learned.basal[hour], applied.basal[hour],
                learned.isf[hour], applied.isf[hour],
                learned.carbRatio[hour], applied.carbRatio[hour]
            ))
        }
        return lines.joined(separator: "\n")
    }

    static func deliveredBasal(_ dataset: RheosDataset, scheduledBasal: [Double], calendar: Calendar) -> String {
        let factors = RheosDeliveredBasal.factors(dataset: dataset, scheduledBasal: scheduledBasal, calendar: calendar)
        var lines = ["Stunde | abgegeben ÷ geplant (ruhige Nüchternstunden)"]
        for hour in 0 ..< 24 {
            if let value = factors[hour] {
                lines.append(String(format: "%02d | %.2f", hour, value))
            }
        }
        if lines.count == 1 {
            return "Noch zu wenig ruhige Nüchternstunden mit Temp-Daten. Gebraucht werden mindestens 5 Tage je Stunde."
        }
        return lines.joined(separator: "\n")
    }

    static func activity(_ dataset: RheosDataset, days: Int, now: Date, calendar: Calendar) -> String {
        let start = now.addingTimeInterval(-Double(days) * 86400)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "EE dd.MM. HH:mm"
        var lines: [String] = []
        let workouts = dataset.workouts.filter { $0.start >= start && $0.start <= now }.sorted { $0.start > $1.start }
        lines.append(workouts.isEmpty ? "Keine Trainings." : "Trainings:")
        for workout in workouts.prefix(20) {
            let heart = workout.averageHeartRate.map { String(format: ", Puls %.0f", $0) } ?? ""
            lines.append("\(formatter.string(from: workout.start)) \(workout.activity), \(Int(workout.durationMinutes)) min\(heart)")
        }
        var sleepByNight: [Date: TimeInterval] = [:]
        for interval in dataset.sleep where interval.end >= start && !interval.stage.lowercased().contains("awake") {
            sleepByNight[calendar.startOfDay(for: interval.end), default: 0] += interval.end.timeIntervalSince(interval.start)
        }
        if !sleepByNight.isEmpty {
            lines.append("Schlaf je Nacht (Stunden):")
            let dayFormat = DateFormatter()
            dayFormat.calendar = calendar
            dayFormat.timeZone = calendar.timeZone
            dayFormat.locale = Locale(identifier: "de_DE")
            dayFormat.dateFormat = "EE dd.MM."
            for (night, seconds) in sleepByNight.sorted(by: { $0.key > $1.key }) {
                lines.append(String(format: "%@ %.1f", dayFormat.string(from: night), seconds / 3600))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func recovery(_ dataset: RheosDataset, days: Int, scheduledBasal: [Double], now: Date, calendar: Calendar) -> String {
        let start = calendar.startOfDay(for: now.addingTimeInterval(-Double(days) * 86400))
        let rows = dataset.wearableDays.filter { $0.day >= start }.sorted { $0.day > $1.day }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "EE dd.MM."
        func value(_ number: Double?, _ format: String) -> String {
            number.map { String(format: format, $0) } ?? "–"
        }
        var lines = ["Tag | Erholung | HRV ms | Ruhepuls | Schlaf h"]
        for row in rows {
            lines.append(
                "\(formatter.string(from: row.day)) | \(value(row.recoveryScore, "%.0f")) | \(value(row.hrvSDNN, "%.0f")) | \(value(row.restingHeartRate, "%.0f")) | \(value(row.sleepHours, "%.1f"))"
            )
        }
        let status = RheosRecovery.status(dataset: dataset, scheduledBasal: scheduledBasal, accepted: false, now: now, calendar: calendar)
        lines.append(status.detail)
        return lines.joined(separator: "\n")
    }

    private static func percent(_ count: Int, of total: Int) -> Double {
        total > 0 ? Double(count) / Double(total) * 100 : 0
    }
}
