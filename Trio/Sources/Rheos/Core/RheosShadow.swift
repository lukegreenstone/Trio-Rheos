import Foundation

enum RheosModelCard {
    static func line(trained: Bool, networkMAE: Double?, ridgeMAE: Double?, source: String) -> String {
        guard trained, networkMAE != nil || ridgeMAE != nil else {
            return "Noch nicht trainiert, zu wenig Daten."
        }
        func number(_ value: Double?) -> String {
            guard let value else { return "—" }
            return String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
        }
        return "Netz \(number(networkMAE)) mg/dL, Ridge \(number(ridgeMAE)) mg/dL, gewählt \(source)."
    }
}

struct RheosShadowStatus: Codable, Equatable {
    var trained: Bool = false
    var source: String = "median"
    var mae: Double? = nil
    var networkMAE: Double? = nil
    var ridgeMAE: Double? = nil
    var baselineMAE: Double? = nil
    var sampleCount: Int = 0
}

struct RheosWeekComparison: Codable, Equatable, Identifiable {
    var id: String
    var start: Date
    var rheosMAE: Double?
    var networkMAE: Double? = nil
    var ridgeMAE: Double? = nil
    var trioMAE: Double?
    var actualInsulin: Double
    var meanShadowBasalFactor: Double
    var nearTarget100: Double?
    /// Always true. These numbers are not a counterfactual replay of the other system.
    var shadowOnly: Bool = true
    var summary: String
}

struct RheosPresetRun: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var started: Date
    var ends: Date
    var prompted: Bool
}

struct RheosMealEstimate: Codable, Equatable {
    var carbs: Double
    var fat: Double
    var protein: Double
    var kcal: Double?
    var note: String
}

enum RheosMealDraftStore {
    static let key = "rheos.mealDraft"

    @discardableResult
    static func save(_ estimate: RheosMealEstimate, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(estimate) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    static func peek(defaults: UserDefaults = .standard) -> RheosMealEstimate? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RheosMealEstimate.self, from: data)
    }

    static func take(defaults: UserDefaults = .standard) -> RheosMealEstimate? {
        let value = peek(defaults: defaults)
        defaults.removeObject(forKey: key)
        return value
    }
}

enum RheosRamp {
    /// First Scharf calendar day uses the 10–20% setting. Later days may step faster.
    /// A missing start date is treated as the first day.
    static func maxStep(now: Date, scharfSince: Date?, bounds: RheosBounds, calendar: Calendar) -> Double {
        let limits = bounds.sanitized()
        guard let scharfSince else { return limits.firstDayMaxChange }
        if calendar.isDate(scharfSince, inSameDayAs: now) { return limits.firstDayMaxChange }
        return limits.laterDayMaxChange
    }

    static func preview(learned: RheosHourlyFactors, step: Double, shadow: RheosShadowStatus) -> String {
        let noon = learned.basal.count == 24 ? learned.basal[12] : 1
        let accuracy: String
        if let mae = shadow.mae {
            accuracy = String(format: "Schatten-Prognosefehler %.1f mg/dL", mae)
            + (shadow.trained ? " (Core-ML-Kern, geprüft)." : " (Median, Core ML noch nicht trainiert).")
        } else {
            accuracy = "Noch keine Schatten-Prognosegüte."
        }
        return String(
            format: "Vorschau, noch nicht angewendet. Mittags-Basalfaktor %.2f, erster Schritt höchstens %.0f %%. %@ SMB und UAM bleiben Trios Algorithmus. Kein Bolus.",
            noon,
            step * 100,
            accuracy
        )
    }
}

enum RheosShadowCompare {
    /// Shadow scores against the glucose that actually happened.
    /// Trio's column is distance from the saved target, not a second simulated loop.
    static func week(
        dataset: RheosDataset,
        fit: RheosCoreFit,
        now: Date,
        calendar: Calendar
    ) -> RheosWeekComparison {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let points = dataset.glucose.filter {
            $0.date >= start && $0.date <= now && $0.mgdl > 0
        }
        let insulin = dataset.insulin.filter { $0.date >= start && $0.date <= now }.reduce(0) { $0 + $1.units }
        let targetErrors = points.map { abs($0.mgdl - 100) }
        let trioMAE = targetErrors.isEmpty ? nil : targetErrors.reduce(0, +) / Double(targetErrors.count)
        let near = points.isEmpty ? nil : Double(points.filter { abs($0.mgdl - 100) <= 15 }.count) / Double(points.count)
        let meanBasal = fit.factors.basal.isEmpty ? 1 : fit.factors.basal.reduce(0, +) / Double(fit.factors.basal.count)
        let id = weekID(start, calendar: calendar)
        let trioText = trioMAE.map { String(format: "%.1f", $0) } ?? "—"
        let modelText = RheosModelCard.line(
            trained: fit.weights.networkMAE != nil || fit.weights.ridgeMAE != nil,
            networkMAE: fit.weights.networkMAE,
            ridgeMAE: fit.weights.ridgeMAE,
            source: fit.chosen
        )
        let summary = "Schattenvergleich \(id), kein kontrafaktisches Ergebnis. \(modelText) Abstand zum Ziel 100 \(trioText) mg/dL. Tatsächliches Insulin \(String(format: "%.1f", insulin)) E. Mittlerer Schatten-Basalfaktor \(String(format: "%.2f", meanBasal))."
        return RheosWeekComparison(
            id: id,
            start: start,
            rheosMAE: fit.weights.mae,
            networkMAE: fit.weights.networkMAE,
            ridgeMAE: fit.weights.ridgeMAE,
            trioMAE: trioMAE,
            actualInsulin: insulin,
            meanShadowBasalFactor: meanBasal,
            nearTarget100: near,
            shadowOnly: true,
            summary: summary
        )
    }

    static func weekID(_ start: Date, calendar: Calendar) -> String {
        let year = calendar.component(.yearForWeekOfYear, from: start)
        let week = calendar.component(.weekOfYear, from: start)
        return String(format: "%d-W%02d", year, week)
    }
}

enum RheosSignalCatalog {
    static let names = [
        "Ruhepuls",
        "Herzfrequenz",
        "HRV (SDNN)",
        "Atemfrequenz",
        "Sauerstoffsättigung",
        "Handgelenktemperatur",
        "Schritte",
        "Aktivenergie",
        "Workout-Minuten",
        "Schlaf-Stunden",
        "Erholungsindex"
    ]

    /// Only names Luke has accepted. Anything else stays out of the dosing features.
    static func values(accepted: [String], day: RheosWearableDay?) -> [Double] {
        let allowed = Set(accepted)
        return names.compactMap { name in
            guard allowed.contains(name) else { return nil }
            return scaled(name, day: day)
        }
    }

    static func scaled(_ name: String, day: RheosWearableDay?) -> Double {
        switch name {
        case "Ruhepuls": return ((day?.restingHeartRate ?? 60) - 60) / 10
        case "Herzfrequenz": return ((day?.heartRate ?? 70) - 70) / 20
        case "HRV (SDNN)": return (day?.hrvSDNN ?? 40) / 40
        case "Atemfrequenz": return (day?.respiratoryRate ?? 16) / 8
        case "Sauerstoffsättigung": return ((day?.oxygenSaturation ?? 0.97) - 0.95) / 0.05
        case "Handgelenktemperatur": return day?.wristTemperature ?? 0
        case "Schritte": return (day?.steps ?? 0) / 10_000
        case "Aktivenergie": return (day?.activeEnergy ?? 0) / 500
        case "Workout-Minuten": return (day?.workoutMinutes ?? 0) / 60
        case "Schlaf-Stunden": return (day?.sleepHours ?? 0) / 8
        case "Erholungsindex": return ((day?.recoveryScore ?? 50) - 50) / 15
        default: return 0
        }
    }
}

enum RheosPresetPlan {
    static func missingMessage(name: String) -> String {
        "Kein gespeichertes Trio-Preset „\(name)“. Rheos erfindet keine Prozente und kein Ziel."
    }

    static func startedMessage(name: String, kind: String) -> String {
        "\(kind) „\(name)“ gestartet, mit der Dauer aus dem gespeicherten Preset. Kein Bolus und keine neuen Grenzen."
    }

    static func ends(started: Date, minutes: Double?) -> Date {
        let duration = minutes ?? (6 * 60)
        return started.addingTimeInterval(max(duration, 15) * 60)
    }
}

enum RheosMealParser {
    /// All-zero macros are a copied template, not a meal. Callers show a message instead.
    static func estimate(in text: String) -> RheosMealEstimate? {
        let stripped = stripFences(text)
        if let meal = object(in: stripped) { return meal }
        guard let regex = try? NSRegularExpression(pattern: #"\{[^{}]*\}"#),
              let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let range = Range(match.range, in: stripped) else { return nil }
        return object(in: String(stripped[range]))
    }

    static func stripFences(_ text: String) -> String {
        var copy = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.hasPrefix("```") {
            if let firstNewline = copy.firstIndex(of: "\n") {
                copy = String(copy[copy.index(after: firstNewline)...])
            }
            if let fence = copy.range(of: "```", options: .backwards) {
                copy = String(copy[..<fence.lowerBound])
            }
        }
        return copy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func object(in text: String) -> RheosMealEstimate? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let carbs = number(json["carbs"]) else { return nil }
        let fat = number(json["fat"]) ?? 0
        let protein = number(json["protein"]) ?? 0
        guard carbs > 0 || fat > 0 || protein > 0 else { return nil }
        return RheosMealEstimate(
            carbs: carbs,
            fat: fat,
            protein: protein,
            kcal: number(json["kcal"]) ?? (4 * carbs + 9 * fat + 4 * protein),
            note: "Schätzung, bitte prüfen"
        )
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }
}

enum RheosCloudContent {
    /// Chat content may be a string or a list of text parts. Never includes a secret.
    static func text(from content: Any?) -> String? {
        if let value = content as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let parts = content as? [String] {
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        if let parts = content as? [[String: Any]] {
            return joinedText(parts.map { $0 as Any })
        }
        if let parts = content as? [Any] {
            return joinedText(parts)
        }
        return nil
    }

    private static func joinedText(_ parts: [Any]) -> String? {
        let joined = parts.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let part = item as? [String: Any], let text = part["text"] as? String { return text }
            return nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

enum RheosFPUSplit {
    /// Evening meals keep less of the fat/protein effect up front. The numbers
    /// are a proposal for Trio's existing FPU entry, not a bolus command.
    static func proposal(hour: Int, fat: Double, protein: Double) -> String {
        let fpu = (fat + protein) * 0.1
        guard fpu > 0 else {
            return "Wenig Fett und Protein. Trio kann die Kohlenhydrate normal eintragen. Rheos gibt keinen Bolus."
        }
        let nowShare = (hour >= 18 || hour < 5) ? 0.4 : 0.6
        return String(
            format: "Vorschlag mit Bestätigung: etwa %.0f %% der Mahlzeit jetzt, den Rest über Trios FPU-Verteilung (%.1f FPU, Warschau). Abends bleibt mehr hinten. Rheos ändert den Reduced-Bolus-Prozentsatz nicht und gibt keinen Bolus.",
            nowShare * 100,
            fpu
        )
    }
}

enum RheosChatSituation {
    static func advice(question: String, forecast: String) -> (kind: String, text: String)? {
        let asked = question.lowercased()
        if asked.contains("sport") || asked.contains("training") {
            return ("sport", "Sport: \(forecast) Bestätigung startet das gespeicherte Preset Sport, falls es existiert. Kein Bolus.")
        }
        if asked.contains("auftritt") || asked.contains("show") || asked.contains("bühne") {
            return ("showtime", "Auftritt: \(forecast) Bestätigung startet das gespeicherte Preset Showtime, falls es existiert. Kein Bolus.")
        }
        if asked.contains("krank") || asked.contains("fieber") {
            return ("krank", "Krank: \(forecast) Bestätigung startet das gespeicherte Preset Krank, falls es existiert. Keine Ketone-Erinnerung und kein Bolus.")
        }
        return nil
    }

    static func forecastLine(mae: Double?) -> String {
        if let mae {
            return String(format: "Schattenprognose, Fehler zuletzt %.0f mg/dL. ", mae)
        }
        return "Noch keine geprüfte Schattenprognose. "
    }
}

/// Rheos Pilot: an own dosing rule that runs only in shadow. It replays every stored loop of the last
/// weeks with the state Trio had at that moment (glucose, trend, IOB, COB, ISF, carb ratio, target),
/// decides what it would have done, and is scored against what happened afterwards and against what
/// oref decided. It never doses and never changes a setting.
///
/// The rule is deliberately plain and readable: a glucose forecast from trend, insulin on board and
/// carbs on board; no insulin when the forecast or glucose is under 80; half of the insulin needed for
/// the target as an SMB, capped at one hour of basal; a lower temp when the forecast is below target.
enum RheosPilot {
    static let reportKey = "rheos.pilot.report"

    struct Inputs {
        var glucose: Double
        var deltaPer5: Double
        var iob: Double
        var cob: Double
        var isf: Double
        var carbRatio: Double
        var target: Double
        var basal: Double
    }

    struct Decision: Equatable {
        var rate: Double
        var smb: Double
        var eventual: Double
        var minPredicted: Double
    }

    struct Report: Codable, Equatable {
        var evaluatedAt: Date
        var loops: Int
        var days: Int
        var pilotError: Double?
        var orefError: Double?
        var trioISFError: Double?
        var rheosISFError: Double?
        var lowsAfter: Int
        var pilotLessBeforeLows: Int
        var pilotMoreBeforeLows: Int
        var highsAfter: Int
        var pilotMoreBeforeHighs: Int
        var pilotLessBeforeHighs: Int
        var ready: Bool
        var lines: [String]
    }

    static func decide(_ inputs: Inputs) -> Decision {
        let isf = max(inputs.isf, 1)
        let csf = inputs.carbRatio > 0 ? isf / inputs.carbRatio : 0
        let pred30 = inputs.glucose + inputs.deltaPer5 * 3 - 0.15 * inputs.iob * isf + min(inputs.cob, 15) * csf
        let pred60 = inputs.glucose + inputs.deltaPer5 * 4 - 0.35 * inputs.iob * isf + min(inputs.cob, 30) * csf
        let eventual = inputs.glucose + inputs.deltaPer5 * 4 - inputs.iob * isf + inputs.cob * csf
        let minPredicted = min(inputs.glucose, pred30, pred60)
        if inputs.glucose < 80 || minPredicted < 80 {
            return Decision(rate: 0, smb: 0, eventual: eventual, minPredicted: minPredicted)
        }
        let need = (eventual - inputs.target) / isf
        if need <= 0 {
            return Decision(rate: max(0, inputs.basal + need * 2), smb: 0, eventual: eventual, minPredicted: minPredicted)
        }
        let smb = min(need * 0.5, max(inputs.basal, 0.1))
        return Decision(rate: inputs.basal, smb: (smb / 0.05).rounded(.down) * 0.05, eventual: eventual, minPredicted: minPredicted)
    }

    /// Replays the stored loops. `profileISF` (mg/dL per U) and the learned ISF factors give the
    /// Rheos-ISF variant; the Trio variant uses the ISF oref used at that loop (Dynamic ISF included).
    static func evaluate(
        dataset: RheosDataset,
        scheduledBasal: [Double],
        profileISF: [Double],
        learned: RheosHourlyFactors?,
        now: Date,
        calendar: Calendar
    ) -> Report {
        let glucose = dataset.glucose.filter { $0.mgdl > 0 && $0.mgdl.isFinite }.sorted { $0.date < $1.date }
        let dates = glucose.map(\.date)
        func value(at date: Date, within: TimeInterval) -> Double? {
            guard let index = RheosStats.nearestIndex(sortedDates: dates, to: date),
                  abs(dates[index].timeIntervalSince(date)) <= within else { return nil }
            return glucose[index].mgdl
        }
        func lowerBound(_ date: Date) -> Int {
            var low = 0
            var high = dates.count
            while low < high {
                let middle = (low + high) / 2
                if dates[middle] < date { low = middle + 1 } else { high = middle }
            }
            return low
        }
        func window(_ from: Date, _ to: Date) -> [Double] {
            var values: [Double] = []
            var index = lowerBound(from)
            while index < glucose.count, glucose[index].date <= to {
                values.append(glucose[index].mgdl)
                index += 1
            }
            return values
        }
        var pilotErrors: [Double] = []
        var orefErrors: [Double] = []
        var trioISF: [Double] = []
        var rheosISF: [Double] = []
        var lows = 0, lessBeforeLows = 0, moreBeforeLows = 0
        var highs = 0, moreBeforeHighs = 0, lessBeforeHighs = 0
        var days = Set<Date>()
        var loops = 0
        let canCompareISF = profileISF.count == 24 && (learned?.isf.count ?? 0) == 24
        for state in dataset.states.sorted(by: { $0.date < $1.date }) {
            guard let current = state.glucose ?? value(at: state.date, within: 6 * 60),
                  let isf = state.dynamicISF, isf > 0,
                  let ratio = state.carbRatio, ratio > 0,
                  let earlier = value(at: state.date.addingTimeInterval(-15 * 60), within: 5 * 60),
                  let actual = value(at: state.date.addingTimeInterval(3 * 3600), within: 10 * 60)
            else { continue }
            let hour = calendar.component(.hour, from: state.date)
            let basal = scheduledBasal.count == 24 ? scheduledBasal[hour] : 0
            let inputs = Inputs(
                glucose: current,
                deltaPer5: (current - earlier) / 3,
                iob: state.iob ?? 0,
                cob: state.cob ?? 0,
                isf: isf,
                carbRatio: ratio,
                target: state.target ?? 100,
                basal: basal
            )
            let pilot = decide(inputs)
            loops += 1
            days.insert(calendar.startOfDay(for: state.date))
            pilotErrors.append(abs(pilot.eventual - actual))
            if let eventual = state.eventualBG { orefErrors.append(abs(eventual - actual)) }
            if canCompareISF, let learned {
                var rheos = inputs
                rheos.isf = profileISF[hour] * learned.isf[hour]
                trioISF.append(abs(pilot.eventual - actual))
                rheosISF.append(abs(decide(rheos).eventual - actual))
            }
            // Insulin each side adds over the next 30 minutes, relative to scheduled basal.
            let orefTemp = state.rate.map { rate in (state.duration ?? 0) > 0 ? (rate - basal) * 0.5 : 0 } ?? 0
            let orefNet = (state.smb ?? 0) + orefTemp
            let pilotNet = pilot.smb + (pilot.rate - basal) * 0.5
            let next2h = window(state.date, state.date.addingTimeInterval(2 * 3600))
            let next3h = window(state.date, state.date.addingTimeInterval(3 * 3600))
            if let low = next2h.min(), low < 70 {
                lows += 1
                if pilotNet < orefNet - 0.05 { lessBeforeLows += 1 } else if pilotNet > orefNet + 0.05 { moreBeforeLows += 1 }
            } else if let high = next3h.max(), high > 180, (next3h.min() ?? 100) >= 80 {
                highs += 1
                if pilotNet > orefNet + 0.05 { moreBeforeHighs += 1 } else if pilotNet < orefNet - 0.05 { lessBeforeHighs += 1 }
            }
        }
        let pilotError = RheosStats.mean(pilotErrors)
        let orefError = RheosStats.mean(orefErrors)
        let trioError = RheosStats.mean(trioISF)
        let rheosError = RheosStats.mean(rheosISF)
        let safer = lessBeforeLows >= 2 * max(1, moreBeforeLows)
        let firmer = moreBeforeHighs >= lessBeforeHighs
        let forecasts = (pilotError ?? .infinity) <= (orefError ?? 0) * 0.95
        let ready = days.count >= 28 && safer && firmer && forecasts
        var lines: [String] = []
        if loops == 0 {
            lines.append("Rheos Pilot: noch keine nachrechenbaren Loops. Gebraucht werden gespeicherte Entscheidungen mit ISF und KH-Faktor und Glukose 3 Stunden danach.")
        } else {
            lines.append("Rheos Pilot (Schatten) über \(loops) Loops an \(days.count) Tagen. Er hat nichts dosiert.")
            if let pilotError, let orefError {
                lines.append(String(format: "Vorhersage für 3 Stunden: Pilot im Mittel %.0f mg/dL daneben, oref %.0f mg/dL.", pilotError, orefError))
            }
            lines.append("Vor \(lows) späteren Unterzuckern hätte der Pilot \(lessBeforeLows)-mal weniger und \(moreBeforeLows)-mal mehr Insulin gegeben als oref.")
            lines.append("Vor \(highs) späteren Hochs ohne Unterzucker hätte er \(moreBeforeHighs)-mal mehr und \(lessBeforeHighs)-mal weniger gegeben.")
            if let trioError, let rheosError {
                let better = rheosError < trioError ? "Der von Rheos gelernte ISF" : "Trios ISF (bei dir mit Dynamic ISF)"
                lines.append(String(format: "ISF-Vergleich: mit Trios ISF %.0f, mit Rheos-ISF %.0f mg/dL Fehler. %@ beschreibt deinen Verlauf hier besser.", trioError, rheosError, better))
            }
            lines.append(ready
                ? "Reif zum Vergleich mit echter Steuerung: über 4 Wochen, sicherer vor Unterzuckern, nicht zögerlicher vor Hochs und bessere Vorhersage. Die Übernahme entscheidest du."
                : "Noch nicht reif: gebraucht werden 4 Wochen, weniger Insulin vor Unterzuckern, mindestens so viel vor Hochs und eine bessere Vorhersage als oref.")
        }
        return Report(
            evaluatedAt: now,
            loops: loops,
            days: days.count,
            pilotError: pilotError,
            orefError: orefError,
            trioISFError: trioError,
            rheosISFError: rheosError,
            lowsAfter: lows,
            pilotLessBeforeLows: lessBeforeLows,
            pilotMoreBeforeLows: moreBeforeLows,
            highsAfter: highs,
            pilotMoreBeforeHighs: moreBeforeHighs,
            pilotLessBeforeHighs: lessBeforeHighs,
            ready: ready,
            lines: lines
        )
    }

    static func save(_ report: Report, defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) { defaults.set(data, forKey: reportKey) }
    }

    static func load(_ defaults: UserDefaults = .standard) -> Report? {
        guard let data = defaults.data(forKey: reportKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Report.self, from: data)
    }
}
