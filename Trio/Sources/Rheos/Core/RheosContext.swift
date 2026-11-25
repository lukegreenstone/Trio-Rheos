import Foundation

/// A situation Rheos noticed from glucose or from Health data that has already arrived.
///
/// `insulinNeed` below 1 means less insulin (more sensitive). It never leaves 0.90...1.10.
/// HealthKit is not live: workouts count only after they have ended, sleep only after
/// the interval has ended, steps only once the day is mostly done.
struct RheosInferredContext: Equatable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var insulinNeed: Double
    var from: Date
    var until: Date
}

enum RheosContextInference {
    static func infer(
        dataset: RheosDataset,
        targets: RheosTargetSchedule = .flat(RheosReference.missingTargetFallbackMgdl),
        recovery: RheosRecovery.Effect? = nil,
        now: Date,
        calendar: Calendar
    ) -> [RheosInferredContext] {
        var found: [RheosInferredContext] = []
        found.append(contentsOf: workouts(dataset.workouts, now: now))
        if let steps = steps(dataset.wearableDays, now: now, calendar: calendar) { found.append(steps) }
        // A learned recovery effect replaces the two fixed rules below: it already contains resting
        // heart rate and sleep, and it uses this person's own response instead of +8 % and +6 %.
        if let recovery, let context = recoveryContext(recovery, days: dataset.wearableDays, now: now, calendar: calendar) {
            found.append(context)
        } else {
            if let pulse = restingHeart(dataset.wearableDays, now: now, calendar: calendar) { found.append(pulse) }
            if let sleep = shortSleep(dataset.sleep, now: now, calendar: calendar) { found.append(sleep) }
        }
        if let rise = unannouncedRise(dataset: dataset, targets: targets, now: now, calendar: calendar) { found.append(rise) }
        if routineIsUnsettled(dataset: dataset, now: now, calendar: calendar) {
            found = found.map { context in
                var copy = context
                copy.insulinNeed = 1 + (context.insulinNeed - 1) * 0.5
                return copy
            }
            found.append(
                RheosInferredContext(
                    id: "routine",
                    title: "Unruhiger Tagesablauf",
                    summary: "Schlaf oder Schritte weichen stark vom Üblichen ab. Rheos dämpft die Kontext-Anpassung und wartet auf mehr Daten. Eine Ankündigung ist nicht nötig.",
                    insulinNeed: 1,
                    from: now,
                    until: now.addingTimeInterval(6 * 3600)
                )
            )
        }
        return found
    }

    static func insulinNeedByHour(
        _ contexts: [RheosInferredContext],
        maxNudge: Double = RheosReference.defaultMaxContextNudge,
        now: Date,
        calendar: Calendar
    ) -> [Double] {
        let cap = min(max(maxNudge, 0.01), RheosReference.maxContextNudgeCap)
        let start = calendar.startOfDay(for: now)
        return (0 ..< 24).map { hour in
            guard let slot = calendar.date(byAdding: .hour, value: hour, to: start) else { return 1 }
            let slotEnd = slot.addingTimeInterval(3600)
            var need = 1.0
            for context in contexts where abs(context.insulinNeed - 1) > 0.000_1 {
                if context.from < slotEnd, context.until > slot {
                    need *= context.insulinNeed
                }
            }
            return min(max(need, 1 - cap), 1 + cap)
        }
    }

    /// Basal moves with insulin need. ISF and carb ratio move the other way
    /// (a higher need lowers the mg/dL-per-unit and the grams-per-unit).
    static func combine(slow: RheosHourlyFactors, insulinNeed: [Double], band: ClosedRange<Double>) -> RheosHourlyFactors {
        func mix(_ values: [Double], invert: Bool) -> [Double] {
            guard values.count == 24, insulinNeed.count == 24 else { return values }
            return zip(values, insulinNeed).map { value, need in
                let safeNeed = need > 0 ? need : 1
                let multiplier = invert ? (1 / safeNeed) : safeNeed
                return min(max(value * multiplier, band.lowerBound), band.upperBound)
            }
        }
        return RheosHourlyFactors(
            basal: mix(slow.basal, invert: false),
            isf: mix(slow.isf, invert: true),
            carbRatio: mix(slow.carbRatio, invert: true)
        )
    }

    static func suggestion(forAnnouncement kind: String) -> String {
        switch kind {
        case "meal":
            return "Ankündigung gespeichert. Das ist nur ein früher Hinweis: einen Bolus kannst du in Trio selbst prüfen. Rheos gibt ihn nicht. Ohne Ankündigung erkennt Rheos den Anstieg später an der Glukose und passt höchstens ISF, KH-Faktor und Basal im Band an."
        default:
            return "Ankündigung gespeichert. Sie ist freiwillig. Scharf passt ISF, KH-Faktor und Basal an, sobald Training, Puls oder Schlaf in Health stehen. Rheos aktiviert kein Preset und gibt keinen Bolus."
        }
    }

    private static func workouts(_ workouts: [RheosWorkout], now: Date) -> [RheosInferredContext] {
        workouts.compactMap { workout in
            guard workout.durationMinutes >= 20 else { return nil }
            let end = workout.start.addingTimeInterval(workout.durationMinutes * 60)
            guard end <= now, now.timeIntervalSince(end) <= 18 * 3600 else { return nil }
            let name = workout.activity.lowercased()
            let intense = name.contains("hiit") || (workout.averageHeartRate ?? 0) >= 150
            let strength = name.contains("kraft") || name.contains("strength")
            let need = intense ? 1.04 : (strength ? 0.96 : 0.90)
            let title = intense ? "Intensives Training" : (strength ? "Krafttraining" : "Training")
            return RheosInferredContext(
                id: "workout-\(workout.id)",
                title: title,
                summary: "\(workout.activity) ist beendet. HealthKit liefert das nicht live, deshalb zählt erst das Ende. Die nächsten Stunden ändern nur ISF, KH-Faktor und Basal im Band. SMB und UAM laufen weiter.",
                insulinNeed: need,
                from: end,
                until: end.addingTimeInterval(18 * 3600)
            )
        }
    }

    private static func steps(_ days: [RheosWearableDay], now: Date, calendar: Calendar) -> RheosInferredContext? {
        guard calendar.component(.hour, from: now) >= 16 else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let current = days.first(where: { calendar.startOfDay(for: $0.day) == today })?.steps else { return nil }
        let history = days.compactMap { day -> Double? in
            guard calendar.startOfDay(for: day.day) < today else { return nil }
            return day.steps
        }
        guard history.count >= 5, let usual = RheosStats.median(history), usual > 0, current > usual * 1.5 else { return nil }
        return RheosInferredContext(
            id: "steps",
            title: "Viel Bewegung",
            summary: "Die Schritte von heute liegen schon über dem üblichen ganzen Tag. Kein Live-Auslöser.",
            insulinNeed: 0.95,
            from: now,
            until: calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(8 * 3600)
        )
    }

    private static func recoveryContext(
        _ effect: RheosRecovery.Effect,
        days: [RheosWearableDay],
        now: Date,
        calendar: Calendar
    ) -> RheosInferredContext? {
        let today = calendar.startOfDay(for: now)
        guard let score = days.first(where: { calendar.isDate($0.day, inSameDayAs: today) })?.recoveryScore else { return nil }
        let need = effect.need(forScore: score)
        guard abs(need - 1) >= 0.01 else { return nil }
        let change = Int(((need - 1) * 100).rounded())
        return RheosInferredContext(
            id: "recovery",
            title: "Erholung \(Int(score.rounded()))/100",
            summary: "Aus HRV, Ruhepuls und Schlaf gegen deine eigenen 30 Tage. Gelernt aus \(effect.days) Tagen: heute \(change > 0 ? "+" : "")\(change) % Insulinbedarf.",
            insulinNeed: need,
            from: today,
            until: calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(12 * 3600)
        )
    }

    private static func restingHeart(_ days: [RheosWearableDay], now: Date, calendar: Calendar) -> RheosInferredContext? {
        let today = calendar.startOfDay(for: now)
        guard let current = days.first(where: { calendar.startOfDay(for: $0.day) == today })?.restingHeartRate else { return nil }
        let history = days.compactMap { day -> Double? in
            guard calendar.startOfDay(for: day.day) < today else { return nil }
            return day.restingHeartRate
        }
        guard history.count >= 5, let usual = RheosStats.median(history), current > usual + 10 else { return nil }
        return RheosInferredContext(
            id: "rhr",
            title: "Ruhepuls erhöht",
            summary: "Der heutige Ruhepuls liegt über der eigenen Basis. Das ist ein Tageswert, kein Schlag-für-Schlag-Signal.",
            insulinNeed: 1.08,
            from: today,
            until: calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(12 * 3600)
        )
    }

    private static func shortSleep(_ sleep: [RheosSleepInterval], now: Date, calendar: Calendar) -> RheosInferredContext? {
        let recent = sleep.filter { $0.end <= now && now.timeIntervalSince($0.end) <= 20 * 3600 }
        let hours = recent.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 3600 }
        guard hours > 0, hours < 6 else { return nil }
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: today) ?? today
        let until = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: today) ?? from.addingTimeInterval(6 * 3600)
        return RheosInferredContext(
            id: "sleep",
            title: "Kurze Nacht",
            summary: "Die letzte abgeschlossene Nacht war unter 6 Stunden. Schlaf kommt erst nach dem Aufwachen in Health an.",
            insulinNeed: 1.06,
            from: from,
            until: until
        )
    }

    private static func unannouncedRise(dataset: RheosDataset, targets: RheosTargetSchedule, now: Date, calendar: Calendar) -> RheosInferredContext? {
        let windowStart = now.addingTimeInterval(-2 * 3600)
        let recent = dataset.glucose.filter { $0.date >= windowStart && $0.date <= now && $0.mgdl > 0 }
        guard let latest = recent.max(by: { $0.date < $1.date }) else { return nil }
        let targetTime = latest.date.addingTimeInterval(-60 * 60)
        guard let earlier = recent.min(by: { abs($0.date.timeIntervalSince(targetTime)) < abs($1.date.timeIntervalSince(targetTime)) }),
              abs(earlier.date.timeIntervalSince(targetTime)) <= 30 * 60 else { return nil }
        let rise = latest.mgdl - earlier.mgdl
        let usual = hourlyMedian(dataset.glucose, hour: calendar.component(.hour, from: latest.date), targets: targets, calendar: calendar)
            - hourlyMedian(dataset.glucose, hour: calendar.component(.hour, from: earlier.date), targets: targets, calendar: calendar)
        let carbs = dataset.meals.contains { $0.carbs > 0 && $0.date >= windowStart && $0.date <= now }
        guard rise > 40, rise > usual + 25, !carbs else { return nil }
        return RheosInferredContext(
            id: "unannounced-rise",
            title: "Anstieg ohne Eintrag",
            summary: "Die Glukose ist stärker gestiegen als in dieser Stunde üblich, ohne Kohlenhydrat-Eintrag. Trio korrigiert über SMB und UAM. Rheos gibt keinen Bolus.",
            insulinNeed: 1.06,
            from: now,
            until: now.addingTimeInterval(3 * 3600)
        )
    }

    private static func routineIsUnsettled(dataset: RheosDataset, now: Date, calendar: Calendar) -> Bool {
        guard calendar.component(.hour, from: now) >= 18 else { return false }
        let today = calendar.startOfDay(for: now)
        guard let current = dataset.wearableDays.first(where: { calendar.startOfDay(for: $0.day) == today })?.steps else { return false }
        let history = dataset.wearableDays.compactMap { day -> Double? in
            guard calendar.startOfDay(for: day.day) < today else { return nil }
            return day.steps
        }
        guard history.count >= 5, let usual = RheosStats.median(history), usual > 0 else { return false }
        return current > usual * 2 || current < usual * 0.4
    }

    private static func hourlyMedian(
        _ glucose: [RheosGlucosePoint],
        hour: Int,
        targets: RheosTargetSchedule,
        calendar: Calendar
    ) -> Double {
        let values = glucose.compactMap { point -> Double? in
            guard calendar.component(.hour, from: point.date) == hour else { return nil }
            return point.mgdl
        }
        return RheosStats.median(values) ?? targets.value(atHour: hour)
    }
}

/// Daily recovery the way recovery apps score a night, from the person's own baselines: HRV above
/// the usual raises it, resting heart rate above the usual lowers it, sleep shorter than usual lowers
/// it. Each day is compared with the 30 days before it. 50 is an ordinary day.
///
/// How recovery moves insulin need is not assumed. It is learned from the person's own days: the
/// insulin the loop delivered on its own that day, against the median of the 14 days before. The
/// effect is used only with at least 21 such days, a correlation of at least 0.25 and the same
/// direction in the older and the newer half, and only after the user accepted the signal
/// "Erholungsindex" in Rheos Vorschläge. It enters as a same-day context inside the context cap.
enum RheosRecovery {
    static let signalName = "Erholungsindex"
    static let baselineDays = 30
    static let minimumBaselineDays = 7
    static let minimumEffectDays = 21
    /// Largest change in insulin need per standard deviation of recovery.
    static let maximumPerZ = 0.08

    struct Effect: Equatable {
        /// Change in the day's insulin need per standard deviation (15 points) of recovery.
        var perZ: Double
        var days: Int
        var correlation: Double

        func need(forScore score: Double) -> Double {
            1 + perZ * (score - 50) / 15
        }

        var summary: String {
            let worse = Int((abs(perZ) * 100).rounded())
            let direction = perZ < 0 ? "mehr" : "weniger"
            return "Gelernt aus \(days) Tagen (r = \(String(format: "%.2f", correlation))): je 15 Punkte schlechtere Erholung etwa \(worse) % \(direction) Insulin."
        }
    }

    static func annotate(_ days: [RheosWearableDay], calendar: Calendar) -> [RheosWearableDay] {
        let sorted = days.sorted { $0.day < $1.day }
        return sorted.enumerated().map { index, day in
            var copy = day
            let history = Array(sorted[max(0, index - baselineDays) ..< index])
            copy.recoveryScore = score(day, history: history)
            return copy
        }
    }

    static func score(_ day: RheosWearableDay, history: [RheosWearableDay]) -> Double? {
        var parts: [(z: Double, weight: Double)] = []
        if let z = zScore(day.hrvSDNN, history.compactMap(\.hrvSDNN)) { parts.append((z, 0.45)) }
        if let z = zScore(day.restingHeartRate, history.compactMap(\.restingHeartRate)) { parts.append((-z, 0.35)) }
        if let z = zScore(day.sleepHours, history.compactMap(\.sleepHours)) { parts.append((z, 0.20)) }
        // Sleep alone is not a recovery score; HRV or resting heart rate has to be there.
        guard parts.contains(where: { $0.weight >= 0.35 }) else { return nil }
        let total = parts.reduce(0) { $0 + $1.weight }
        let combined = parts.reduce(0) { $0 + $1.z * $1.weight } / total
        return min(100, max(0, 50 + 15 * combined))
    }

    private static func zScore(_ value: Double?, _ history: [Double]) -> Double? {
        let usable = history.filter(\.isFinite)
        guard let value, value.isFinite, usable.count >= minimumBaselineDays, let mean = RheosStats.mean(usable) else { return nil }
        let variance = usable.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(usable.count - 1)
        let spread = max(variance.squareRoot(), abs(mean) * 0.05, 0.001)
        return min(3, max(-3, (value - mean) / spread))
    }

    /// Pairs of (day, recovery in standard deviations, automatic insulin / usual).
    static func pairs(dataset: RheosDataset, scheduledBasal: [Double], calendar: Calendar) -> [(day: Date, z: Double, ratio: Double)] {
        let automatic = RheosDeliveredBasal.dailyAutomatic(dataset: dataset, scheduledBasal: scheduledBasal, calendar: calendar)
            .sorted { $0.key < $1.key }
        var scoreByDay: [Date: Double] = [:]
        for day in dataset.wearableDays {
            if let score = day.recoveryScore { scoreByDay[calendar.startOfDay(for: day.day)] = score }
        }
        var result: [(day: Date, z: Double, ratio: Double)] = []
        for (index, entry) in automatic.enumerated() {
            let before = automatic[max(0, index - 14) ..< index].map { $0.value }
            guard before.count >= 7, let usual = RheosStats.median(before), usual > 0,
                  let score = scoreByDay[entry.key] else { continue }
            result.append((entry.key, (score - 50) / 15, entry.value / usual))
        }
        return result
    }

    static func effect(dataset: RheosDataset, scheduledBasal: [Double], calendar: Calendar) -> Effect? {
        let data = pairs(dataset: dataset, scheduledBasal: scheduledBasal, calendar: calendar)
        guard data.count >= minimumEffectDays, let all = fit(data.map { ($0.z, $0.ratio - 1) }) else { return nil }
        let half = data.count / 2
        guard let older = fit(data.prefix(half).map { ($0.z, $0.ratio - 1) }),
              let newer = fit(data.suffix(data.count - half).map { ($0.z, $0.ratio - 1) }),
              older.slope * newer.slope > 0,
              abs(all.correlation) >= 0.25
        else { return nil }
        return Effect(
            perZ: min(maximumPerZ, max(-maximumPerZ, all.slope)),
            days: data.count,
            correlation: all.correlation
        )
    }

    /// Two lines for the Rheos sheet: today's recovery, and what was learned from it.
    static func status(
        dataset: RheosDataset,
        scheduledBasal: [Double],
        accepted: Bool,
        now: Date,
        calendar: Calendar
    ) -> (headline: String, detail: String) {
        let today = dataset.wearableDays.first { calendar.isDate($0.day, inSameDayAs: now) }
        var headline: String
        if let today, let score = today.recoveryScore {
            var parts = ["Erholung heute \(Int(score.rounded()))/100"]
            if let hrv = today.hrvSDNN { parts.append("HRV \(Int(hrv.rounded())) ms") }
            if let resting = today.restingHeartRate { parts.append("Ruhepuls \(Int(resting.rounded()))") }
            if let sleep = today.sleepHours { parts.append(String(format: "Schlaf %.1f h", sleep)) }
            headline = parts.joined(separator: " · ")
        } else {
            headline = "Erholung heute: noch kein Wert. Gebraucht werden HRV oder Ruhepuls aus Health und 7 Tage Basis."
        }
        let detail: String
        if let effect = effect(dataset: dataset, scheduledBasal: scheduledBasal, calendar: calendar) {
            let use = accepted
                ? "Wirkt in Scharf auf den heutigen Bedarf."
                : "Wirkt erst, wenn du „Erholungsindex“ in den Rheos-Vorschlägen mit Ja bestätigst."
            detail = effect.summary + " " + use
        } else {
            let count = pairs(dataset: dataset, scheduledBasal: scheduledBasal, calendar: calendar).count
            detail = "Noch kein belastbarer Zusammenhang mit deinem Insulinbedarf: \(count) von mindestens \(minimumEffectDays) Tagen mit Erholung und Loop-Daten, oder die Tage zeigen keine einheitliche Richtung."
        }
        headline = headline.replacingOccurrences(of: "  ", with: " ")
        return (headline, detail)
    }

    private static func fit(_ points: [(x: Double, y: Double)]) -> (slope: Double, correlation: Double)? {
        guard points.count >= 4 else { return nil }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for point in points {
            sxx += (point.x - meanX) * (point.x - meanX)
            syy += (point.y - meanY) * (point.y - meanY)
            sxy += (point.x - meanX) * (point.y - meanY)
        }
        guard sxx > 1e-9, syy > 1e-12 else { return nil }
        return (sxy / sxx, sxy / (sxx * syy).squareRoot())
    }
}
