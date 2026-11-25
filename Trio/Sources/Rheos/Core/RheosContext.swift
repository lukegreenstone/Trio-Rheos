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
        // iPhone and watch can both write the same night; overlaps count once.
        let hours = RheosSleepNights.unionHours(recent.map { (start: $0.start, end: $0.end) })
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

    /// Days back Rheos reads from Apple Health for the recovery baseline.
    static let historyDays = 90
    /// Nights the baseline uses, like the calibration window recovery apps use.
    static let baselineNights = 60

    /// Scores each day from the night before it. Days with a measured sleep window use the
    /// night-based score; days without one fall back to the daily averages.
    static func annotate(_ days: [RheosWearableDay], nights: [RheosNight] = [], calendar: Calendar) -> [RheosWearableDay] {
        var rows: [Date: RheosWearableDay] = [:]
        for day in days {
            rows[calendar.startOfDay(for: day.day)] = day
        }
        let earliest = rows.keys.min()
        let sortedNights = nights.sorted { $0.day < $1.day }
        var fromNights: Set<Date> = []
        for (index, night) in sortedNights.enumerated() {
            let key = calendar.startOfDay(for: night.day)
            guard let earliest, key >= earliest else { continue }
            var row = rows[key] ?? RheosWearableDay(day: key)
            // One sleep source, no double counting, assigned to the wake-up day.
            row.sleepHours = night.asleepHours
            let history = Array(sortedNights[max(0, index - baselineNights) ..< index])
            if let result = score(night, history: history, calendar: calendar) {
                row.recoveryScore = result.score
                row.sleepScore = result.sleepScore
                row.recoveryNote = result.note
                fromNights.insert(key)
            } else {
                row.sleepScore = sleepScore(night, history: history, calendar: calendar)
            }
            rows[key] = row
        }
        let sorted = rows.values.sorted { $0.day < $1.day }
        return sorted.enumerated().map { index, day in
            guard !fromNights.contains(calendar.startOfDay(for: day.day)) else { return day }
            var copy = day
            let history = Array(sorted[max(0, index - baselineDays) ..< index])
            copy.recoveryScore = score(day, history: history)
            return copy
        }
    }

    /// Recovery for the morning after `night`, against the person's own nights before it.
    /// HRV 40 %, sleeping heart rate 25 %, sleep score 20 %, breathing rate, wrist temperature and
    /// blood oxygen 5 % each. Breathing and temperature only lower it when raised, blood oxygen only
    /// when low. HRV or sleeping heart rate has to be there. 50 is this person's usual morning.
    static func score(
        _ night: RheosNight,
        history: [RheosNight],
        calendar: Calendar
    ) -> (score: Double, sleepScore: Double?, note: String)? {
        var parts: [(z: Double, weight: Double)] = []
        var notes: [String] = []
        if let rmssd = night.hrvRMSSD, rmssd > 0,
           let z = robustZ(log(rmssd), history.compactMap(\.hrvRMSSD).filter { $0 > 0 }.map { log($0) }, floor: 0.05) {
            parts.append((z, 0.40))
            notes.append(describe("HRV (RMSSD)", rmssd, history.compactMap(\.hrvRMSSD), "%.0f", " ms"))
        } else if let sdnn = night.hrvSDNN, sdnn > 0,
                  let z = robustZ(log(sdnn), history.compactMap(\.hrvSDNN).filter { $0 > 0 }.map { log($0) }, floor: 0.05) {
            parts.append((z, 0.40))
            notes.append(describe("HRV (SDNN)", sdnn, history.compactMap(\.hrvSDNN), "%.0f", " ms"))
        }
        if let heart = night.sleepingHeartRate,
           let z = robustZ(heart, history.compactMap(\.sleepingHeartRate), floor: 1) {
            parts.append((-z, 0.25))
            notes.append(describe("Schlafpuls", heart, history.compactMap(\.sleepingHeartRate), "%.0f", ""))
        }
        guard !parts.isEmpty else { return nil }
        let sleep = sleepScore(night, history: history, calendar: calendar)
        if let sleep {
            parts.append((min(3, max(-3, (sleep - 75) / 12)), 0.20))
            notes.append(String(format: "Schlaf %.1f h, Score %.0f", night.asleepHours, sleep))
        }
        if let breathing = night.respiratoryRate,
           let z = robustZ(breathing, history.compactMap(\.respiratoryRate), floor: 0.3) {
            parts.append((-max(0, z), 0.05))
            notes.append(describe("Atmung", breathing, history.compactMap(\.respiratoryRate), "%.1f", "/min"))
        }
        if let temperature = night.wristTemperature,
           let z = robustZ(temperature, history.compactMap(\.wristTemperature), floor: 0.1),
           let usual = RheosStats.median(history.compactMap(\.wristTemperature)) {
            parts.append((-max(0, z), 0.05))
            notes.append(String(format: "Temperatur %+.1f °C", temperature - usual))
        }
        if let oxygen = night.oxygenSaturation,
           let z = robustZ(oxygen, history.compactMap(\.oxygenSaturation), floor: 0.5) {
            parts.append((min(0, z), 0.05))
            notes.append(String(format: "SpO₂ %.0f %%", oxygen))
        }
        let total = parts.reduce(0) { $0 + $1.weight }
        let combined = parts.reduce(0) { $0 + $1.z * $1.weight } / total
        let score = min(100, max(0, 50 + 15 * combined))
        notes.append("Basis \(history.count) Nächte")
        return (score, sleep, notes.joined(separator: " · "))
    }

    /// 0–100: duration against the person's own need (their median night, kept within 7–9 hours)
    /// 50 %, deep and REM share 20 %, efficiency 15 %, timing against their usual midpoint 15 %.
    static func sleepScore(_ night: RheosNight, history: [RheosNight], calendar: Calendar) -> Double? {
        guard night.asleepHours > 0 else { return nil }
        let need = min(9, max(7, RheosStats.median(history.map(\.asleepHours).filter { $0 >= 3 }) ?? 8))
        var parts: [(value: Double, weight: Double)] = [(min(1, night.asleepHours / need), 0.50)]
        let span = night.end.timeIntervalSince(night.start) / 3600
        if span > 0 {
            let efficiency = min(1, night.asleepHours / span)
            parts.append((min(1, max(0, (efficiency - 0.75) / 0.20)), 0.15))
        }
        if let deep = night.deepHours, let rem = night.remHours {
            parts.append((min(1, max(0, (deep + rem) / night.asleepHours / 0.40)), 0.20))
        }
        let midpoints = history.map { midpoint($0, calendar: calendar) }
        if midpoints.count >= 5, let usual = RheosStats.median(midpoints) {
            let off = abs(midpoint(night, calendar: calendar) - usual)
            parts.append((max(0, 1 - off / 2), 0.15))
        }
        let total = parts.reduce(0) { $0 + $1.weight }
        return 100 * parts.reduce(0) { $0 + $1.value * $1.weight } / total
    }

    /// Hours from noon before the wake-up day to the middle of the night, so 23:00–07:00 is 15.
    private static func midpoint(_ night: RheosNight, calendar: Calendar) -> Double {
        let noon = calendar.startOfDay(for: night.day).addingTimeInterval(-12 * 3600)
        let middle = night.start.addingTimeInterval(night.end.timeIntervalSince(night.start) / 2)
        return middle.timeIntervalSince(noon) / 3600
    }

    /// Distance from the person's own median in robust standard deviations (MAD), within ±3.
    static func robustZ(_ value: Double, _ history: [Double], floor: Double) -> Double? {
        let usable = history.filter(\.isFinite)
        guard value.isFinite, usable.count >= minimumBaselineDays, let median = RheosStats.median(usable),
              let mad = RheosStats.median(usable.map { abs($0 - median) }) else { return nil }
        let spread = max(mad * 1.4826, floor)
        return min(3, max(-3, (value - median) / spread))
    }

    private static func describe(_ name: String, _ value: Double, _ history: [Double], _ format: String, _ unit: String) -> String {
        let now = String(format: format, value)
        guard let usual = RheosStats.median(history.filter(\.isFinite)) else { return "\(name) \(now)\(unit)" }
        return "\(name) \(now)\(unit) (üblich \(String(format: format, usual)))"
    }

    /// RMSSD in ms from a beat-to-beat series (seconds since series start, gap before the beat).
    /// Beat intervals outside 0.3–2 s and jumps over 25 % are treated as artefacts.
    static func rmssd(_ beats: [(time: Double, gap: Bool)]) -> Double? {
        var previousTime: Double?
        var previousInterval: Double?
        var differences: [Double] = []
        for beat in beats.sorted(by: { $0.time < $1.time }) {
            defer { previousTime = beat.time }
            guard let last = previousTime, !beat.gap else {
                previousInterval = nil
                continue
            }
            let interval = beat.time - last
            guard interval >= 0.3, interval <= 2.0 else {
                previousInterval = nil
                continue
            }
            if let previous = previousInterval {
                if abs(interval - previous) <= 0.25 * previous {
                    differences.append(interval - previous)
                } else {
                    previousInterval = nil
                    continue
                }
            }
            previousInterval = interval
        }
        guard differences.count >= 20 else { return nil }
        return (differences.reduce(0) { $0 + $1 * $1 } / Double(differences.count)).squareRoot() * 1000
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
        if let today, let score = today.recoveryScore, let note = today.recoveryNote {
            headline = "Erholung heute \(Int(score.rounded()))/100 · \(note)"
        } else if let today, let score = today.recoveryScore {
            var parts = ["Erholung heute \(Int(score.rounded()))/100"]
            if let hrv = today.hrvSDNN { parts.append("HRV \(Int(hrv.rounded())) ms") }
            if let resting = today.restingHeartRate { parts.append("Ruhepuls \(Int(resting.rounded()))") }
            if let sleep = today.sleepHours { parts.append(String(format: "Schlaf %.1f h", sleep)) }
            headline = parts.joined(separator: " · ")
        } else {
            headline = "Erholung heute: noch kein Wert. Gebraucht werden HRV oder Puls aus der letzten Nacht und 7 Nächte Basis."
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

/// Builds the main sleep of each night from Apple Health's sleep samples. Several apps can write
/// sleep for the same night; each night uses the one source with the most sleep, and overlapping
/// samples are merged, so nothing is counted twice. A night belongs to the day the person woke up.
enum RheosSleepNights {
    struct Sample: Equatable {
        var start: Date
        var end: Date
        /// "asleep", "core", "deep", "rem", "awake" or "inBed".
        var stage: String
        var source: String
    }

    struct Window: Equatable {
        var day: Date
        var start: Date
        var end: Date
        var asleepHours: Double
        var deepHours: Double?
        var remHours: Double?
        var awakeHours: Double
    }

    static let asleepStages: Set<String> = ["asleep", "core", "deep", "rem"]
    /// Pieces of sleep closer than this belong to the same night.
    static let maximumGap: TimeInterval = 60 * 60
    /// Shorter sleep is a nap and not a night.
    static let minimumNightHours = 3.0

    static func windows(_ samples: [Sample], calendar: Calendar) -> [Window] {
        var best: [Date: (window: Window, staged: Bool)] = [:]
        for (_, own) in Dictionary(grouping: samples, by: \.source) {
            let asleep = own.filter { asleepStages.contains($0.stage) && $0.end > $0.start }.sorted { $0.start < $1.start }
            var sessions: [[Sample]] = []
            for sample in asleep {
                if let last = sessions.last?.map(\.end).max(), sample.start.timeIntervalSince(last) <= maximumGap {
                    sessions[sessions.count - 1].append(sample)
                } else {
                    sessions.append([sample])
                }
            }
            for session in sessions {
                guard let start = session.map(\.start).min(), let end = session.map(\.end).max() else { continue }
                let hours = unionHours(spans(session))
                guard hours >= minimumNightHours else { continue }
                let staged = session.contains { $0.stage == "deep" || $0.stage == "rem" || $0.stage == "core" }
                let awake = own.filter { $0.stage == "awake" && $0.start >= start && $0.end <= end }
                let window = Window(
                    day: calendar.startOfDay(for: end),
                    start: start,
                    end: end,
                    asleepHours: hours,
                    deepHours: staged ? stageHours("deep", in: session) : nil,
                    remHours: staged ? stageHours("rem", in: session) : nil,
                    awakeHours: unionHours(spans(awake))
                )
                if let current = best[window.day] {
                    // More sleep wins; with about the same sleep, the source with stages wins.
                    let clearlyLonger = window.asleepHours > current.window.asleepHours + 0.25
                    let sameButStaged = abs(window.asleepHours - current.window.asleepHours) <= 0.25 && staged && !current.staged
                    if clearlyLonger || sameButStaged { best[window.day] = (window, staged) }
                } else {
                    best[window.day] = (window, staged)
                }
            }
        }
        return best.values.map { $0.window }.sorted { $0.day < $1.day }
    }

    private static func spans(_ samples: [Sample]) -> [(start: Date, end: Date)] {
        samples.map { sample -> (start: Date, end: Date) in (start: sample.start, end: sample.end) }
    }

    private static func stageHours(_ stage: String, in session: [Sample]) -> Double {
        unionHours(spans(session.filter { $0.stage == stage }))
    }

    /// Hours covered by the intervals, overlaps counted once.
    static func unionHours(_ intervals: [(start: Date, end: Date)]) -> Double {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: (start: Date, end: Date)?
        for interval in sorted {
            if let open = current, interval.start <= open.end {
                current = (open.start, max(open.end, interval.end))
            } else {
                if let open = current { total += open.end.timeIntervalSince(open.start) }
                current = interval
            }
        }
        if let open = current { total += open.end.timeIntervalSince(open.start) }
        return total / 3600
    }
}
