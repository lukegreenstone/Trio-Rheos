import Foundation

/// The user's Trio BG target, one value per clock hour, in mg/dL.
/// Built from the target schedule Trio already stores. Rheos does not write that schedule.
struct RheosTargetSchedule: Equatable {
    var byHour: [Double]

    static func flat(_ value: Double) -> RheosTargetSchedule {
        RheosTargetSchedule(byHour: Array(repeating: value, count: 24))
    }

    /// `minutes` is minutes from midnight, matching Trio's BG target `offset`.
    /// The reference is the middle of the low/high range. A flat 100/100 target stays 100.
    static func from(entries: [(minutes: Int, low: Double, high: Double)]) -> RheosTargetSchedule {
        let usable = entries.filter { $0.low.isFinite && $0.high.isFinite && $0.low > 0 && $0.high > 0 }
        guard !usable.isEmpty else { return RheosTargetSchedule(byHour: []) }
        let hours = (0 ..< 24).map { hour -> Double in
            let minute = hour * 60
            let active = usable.filter { $0.minutes <= minute }.max(by: { $0.minutes < $1.minutes })
                ?? usable.max(by: { $0.minutes < $1.minutes })
            let low = active?.low ?? usable[0].low
            let high = active?.high ?? usable[0].high
            return (low + high) / 2
        }
        return RheosTargetSchedule(byHour: hours)
    }

    var isComplete: Bool { byHour.count == 24 && byHour.allSatisfy { $0.isFinite && $0 > 0 } }

    func value(atHour hour: Int) -> Double {
        guard isComplete else { return RheosReference.missingTargetFallbackMgdl }
        return byHour[min(23, max(0, hour))]
    }
}

struct RheosMealPresetLearning: Equatable, Identifiable {
    var id: String
    var count: Int
    var medianDelta2h: Double?
    var medianDelta4h: Double?
    var medianAbsorptionHours: Double?
    var lateFatty4amRise: Double?
    /// Text only. Confirming it records a note. It is not a bolus.
    var suggestion: String
}

enum RheosFit {
    struct Observation {
        var day: Date
        var hour: Int
        var glucose: Double
        var target: Double
        var iob: Double
        var activeCarbs: Double
    }

    struct Model {
        var factors: RheosHourlyFactors
        /// mg/dL per unit of IOB. Zero when the fit had the wrong sign.
        var iobSlope: Double
        /// mg/dL per gram of still-active carbohydrate. Zero when the fit had the wrong sign.
        var carbSlope: Double
    }

    static func observations(
        dataset: RheosDataset,
        targets: RheosTargetSchedule,
        calendar: Calendar
    ) -> [Observation] {
        // Sorted once: the nearest loop state is then a binary search, not a scan of every state
        // for every glucose value (45 days made that about 170 million comparisons per call).
        let states = dataset.states.sorted { $0.date < $1.date }
        let stateDates = states.map(\.date)
        return dataset.glucose.compactMap { point in
            guard point.mgdl.isFinite, point.mgdl > 0 else { return nil }
            let hour = calendar.component(.hour, from: point.date)
            let state = nearestState(at: point.date, states: states, dates: stateDates)
            return Observation(
                day: calendar.startOfDay(for: point.date),
                hour: hour,
                glucose: point.mgdl,
                target: targets.value(atHour: hour),
                iob: state.iob,
                activeCarbs: activeCarbs(at: point.date, meals: dataset.meals)
            )
        }
    }

    /// Which factor one glucose value can teach, the split oref Autotune makes.
    /// Absorbing carbs belong to the carb ratio. A correction (IOB of at least
    /// `RheosReference.correctionIOB`) says how strong a unit is: ISF. Everything else is
    /// the background need: basal. One error used for both basal and ISF moved insulin twice.
    enum Lesson {
        case basal
        case isf
        case neither
    }

    static func lesson(iob: Double, activeCarbs: Double) -> Lesson {
        if activeCarbs >= 1 { return .neither }
        return iob >= RheosReference.correctionIOB ? .isf : .basal
    }

    /// Ridge regression of (glucose − target) on IOB and still-active carbs, then a per-hour
    /// factor with shrinkage toward 1 and toward the neighbouring hours. Basal learns from
    /// quiet hours, ISF from correction hours (`lesson`).
    static func fit(observations: [Observation], band: ClosedRange<Double>, priorStrength: Double = RheosBodyPrior.plain) -> Model {
        let slopes = slopes(observations)
        // Recent days count more (half-life `RheosReference.recencyHalfLifeDays`), so the factors
        // follow a change in the person over weeks. The shrinkage below still uses the plain count.
        let newest = observations.map(\.day).max() ?? Date()
        var basalResiduals: [Int: [(value: Double, weight: Double)]] = [:]
        var isfResiduals: [Int: [(value: Double, weight: Double)]] = [:]
        for observation in observations {
            let explained = slopes.iob * observation.iob + slopes.carb * observation.activeCarbs
            let residual = (observation.glucose - observation.target) - explained
            let weighted = (value: residual, weight: RheosReference.recencyWeight(observation.day, newest: newest))
            switch lesson(iob: observation.iob, activeCarbs: observation.activeCarbs) {
            case .basal:
                basalResiduals[observation.hour, default: []].append(weighted)
            case .isf:
                isfResiduals[observation.hour, default: []].append(weighted)
            case .neither:
                break
            }
        }
        var basal = Array(repeating: 1.0, count: 24)
        var isf = Array(repeating: 1.0, count: 24)
        var basalCounts = Array(repeating: 0, count: 24)
        var isfCounts = Array(repeating: 0, count: 24)
        for hour in 0 ..< 24 {
            let target = observations.first { $0.hour == hour }?.target ?? RheosReference.missingTargetFallbackMgdl
            if let values = basalResiduals[hour], values.count >= RheosReference.minimumSamplesPerHour,
               let mean = weightedMean(values)
            {
                basal[hour] = 1 + RheosReference.deviationGain * mean / max(target, 1)
                basalCounts[hour] = values.count
            }
            if let values = isfResiduals[hour], values.count >= RheosReference.minimumSamplesPerHour,
               let mean = weightedMean(values)
            {
                isf[hour] = 1 - RheosReference.deviationGain * mean / max(target, 1)
                isfCounts[hour] = values.count
            }
        }
        basal = smooth(shrink(basal, counts: basalCounts, priorStrength: priorStrength), band: band)
        isf = smooth(shrink(isf, counts: isfCounts, priorStrength: priorStrength), band: band)
        return Model(factors: RheosHourlyFactors(basal: basal, isf: isf, carbRatio: Array(repeating: 1, count: 24)), iobSlope: slopes.iob, carbSlope: slopes.carb)
    }

    private static func weightedMean(_ values: [(value: Double, weight: Double)]) -> Double? {
        let total = values.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        return values.reduce(0) { $0 + $1.value * $1.weight } / total
    }

    static func predict(_ observation: Observation, model: Model) -> Double {
        let factor = model.factors.basal.count == 24 ? model.factors.basal[observation.hour] : 1
        let residual = (factor - 1) / RheosReference.deviationGain * observation.target
        let explained = model.iobSlope * observation.iob + model.carbSlope * observation.activeCarbs
        return observation.target + explained + residual
    }

    static func carbRatioFactors(
        dataset: RheosDataset,
        targets: RheosTargetSchedule,
        band: ClosedRange<Double>,
        calendar: Calendar
    ) -> [Double] {
        var raw = Array(repeating: 1.0, count: 24)
        var counts = Array(repeating: 0, count: 24)
        guard dataset.meals.count >= RheosReference.minimumMealsForCarbRatio else {
            return raw
        }
        var byHour: [Int: [(value: Double, weight: Double)]] = [:]
        let newestMeal = dataset.meals.map(\.date).max() ?? Date()
        let usualShare = RheosStats.median(dataset.meals.compactMap { bolusShare(meal: $0, insulin: dataset.insulin) })
        for meal in dataset.meals {
            guard let before = RheosMealDelta.sample(dataset.glucose, at: meal.date),
                  let after = RheosMealDelta.sample(dataset.glucose, at: meal.date.addingTimeInterval(3 * 3600))
            else { continue }
            let change = after - before
            guard abs(change) <= RheosMealDelta.uncertainMagnitude else { continue }
            let hour = calendar.component(.hour, from: meal.date)
            let target = targets.value(atHour: hour)
            let delta = (change - RheosReference.expectedMealRiseMgdl) / max(target, 1)
            let fromGlucose = 1 - RheosReference.deviationGain * delta
            var fromSMB = 1.0
            if let usualShare, usualShare > 0, let share = bolusShare(meal: meal, insulin: dataset.insulin) {
                fromSMB = min(1.2, max(0.8, (share / usualShare).squareRoot()))
            }
            byHour[hour, default: []].append((
                value: fromGlucose * fromSMB,
                weight: RheosReference.recencyWeight(meal.date, newest: newestMeal)
            ))
        }
        for hour in 0 ..< 24 {
            guard let values = byHour[hour], values.count >= 2, let median = RheosStats.weightedMedian(values) else { continue }
            raw[hour] = median
            counts[hour] = values.count
        }
        return raw.enumerated().map { hour, value in
            let n = Double(counts[hour])
            guard n > 0 else { return 1 }
            let shrunk = (n * value + 2 * 1) / (n + 2)
            return min(max(shrunk, band.lowerBound), band.upperBound)
        }
    }

    /// In a closed loop a weak carb ratio does not show as a high: SMBs catch it, and the glucose
    /// three hours later looks fine. This is the meal bolus's share of all bolus insulin in the first
    /// three hours. Many people enter only part of the calculated bolus on purpose, so the share is
    /// compared with the person's own usual share, not with 100 %: a time of day that needs more
    /// SMB than usual gets a stronger ratio. Without a meal bolus the meal is not used here.
    static func bolusShare(meal: RheosMealEvent, insulin: [RheosInsulinEvent]) -> Double? {
        let bolus = insulin.filter {
            $0.kind == "bolus" && abs($0.date.timeIntervalSince(meal.date)) <= 20 * 60
        }.reduce(0) { $0 + $1.units }
        guard bolus > 0 else { return nil }
        let start = meal.date.addingTimeInterval(-20 * 60)
        let end = meal.date.addingTimeInterval(3 * 3600)
        let smb = insulin.filter { $0.kind == "smb" && $0.date >= start && $0.date <= end }.reduce(0) { $0 + $1.units }
        return bolus / (bolus + smb)
    }

    static func mealPresets(
        dataset: RheosDataset,
        calendar: Calendar
    ) -> [RheosMealPresetLearning] {
        let outcomes = RheosAnalysis.mealOutcomes(dataset: dataset, calendar: calendar)
        let groups = Dictionary(grouping: outcomes, by: \.presetKey)
        return groups.map { key, meals in
            let rises = meals.compactMap(\.riseAt4am)
            let fatty = meals.filter { $0.fat + $0.protein > 0 && calendar.component(.hour, from: $0.date) >= 20 }
            let absorption = meals.compactMap { absorptionHours(for: $0, glucose: dataset.glucose) }
            let delta2 = RheosStats.median(meals.compactMap { RheosMealDelta.usable($0.delta2h) })
            let delta4 = RheosStats.median(meals.compactMap { RheosMealDelta.usable($0.delta4h) })
            let rise = RheosStats.median(rises.filter { abs($0) <= RheosMealDelta.uncertainMagnitude })
            let suggestion: String
            if !fatty.isEmpty, let rise, rise > 20 {
                suggestion = "„\(key)“: nach später fettreicher Mahlzeit liegt der 4-Uhr-Anstieg im Median bei \(Int(rise)) mg/dL. Vorschlag, nur zur Kenntnis: den Eintrag in Trio über mehr Stunden verteilen. Rheos gibt keinen Bolus."
            } else if let delta4, delta4 > 40 {
                suggestion = "„\(key)“: nach 4 Stunden liegt die Glukose im Median noch \(Int(delta4)) mg/dL über dem Start. Ein aufgeteilter Eintrag wäre nur deine Entscheidung in Trio."
            } else {
                suggestion = "„\(key)“: \(meals.count) Mahlzeiten im Protokoll. Kein Dosierungsvorschlag."
            }
            return RheosMealPresetLearning(
                id: key,
                count: meals.count,
                medianDelta2h: delta2,
                medianDelta4h: delta4,
                medianAbsorptionHours: RheosStats.median(absorption),
                lateFatty4amRise: fatty.isEmpty ? nil : rise,
                suggestion: suggestion
            )
        }.sorted { $0.id < $1.id }
    }

    static func activeCarbs(at date: Date, meals: [RheosMealEvent]) -> Double {
        meals.reduce(0) { total, meal in
            let elapsed = date.timeIntervalSince(meal.date) / 3600
            guard elapsed >= 0 else { return total }
            let carbs = elapsed < 3 ? meal.carbs * (1 - elapsed / 3) : 0
            let delayed = elapsed < 6 ? (meal.fat + meal.protein) * 0.1 * (1 - elapsed / 6) : 0
            return total + carbs + delayed
        }
    }

    private static func nearestState(at date: Date, states: [RheosStatePoint], dates: [Date]) -> (iob: Double, cob: Double) {
        guard let index = RheosStats.nearestIndex(sortedDates: dates, to: date) else { return (0, 0) }
        let nearest = states[index]
        guard abs(nearest.date.timeIntervalSince(date)) <= 20 * 60 else { return (0, 0) }
        return (max(0, nearest.iob ?? 0), max(0, nearest.cob ?? 0))
    }

    private static func slopes(_ observations: [Observation]) -> (iob: Double, carb: Double) {
        var sIOB = 0.0, sCarb = 0.0, sIOB2 = 0.0, sCarb2 = 0.0, sCross = 0.0, sYIOB = 0.0, sYCarb = 0.0
        for observation in observations {
            let y = observation.glucose - observation.target
            sIOB += observation.iob
            sCarb += observation.activeCarbs
            sIOB2 += observation.iob * observation.iob
            sCarb2 += observation.activeCarbs * observation.activeCarbs
            sCross += observation.iob * observation.activeCarbs
            sYIOB += y * observation.iob
            sYCarb += y * observation.activeCarbs
        }
        let lambda = 1.0
        let a = sIOB2 + lambda
        let b = sCross
        let c = sCarb2 + lambda
        let det = a * c - b * b
        guard abs(det) > 1e-8 else { return (0, 0) }
        var iob = (c * sYIOB - b * sYCarb) / det
        var carb = (a * sYCarb - b * sYIOB) / det
        if iob > 0 { iob = 0 }
        if carb < 0 { carb = 0 }
        return (iob, carb)
    }

    private static func shrink(_ values: [Double], counts: [Int], priorStrength: Double) -> [Double] {
        let prior = priorStrength > 0 ? priorStrength : RheosBodyPrior.plain
        return zip(values, counts).map { value, count in
            let n = Double(count)
            guard n > 0 else { return 1 }
            return (n * value + prior * 1) / (n + prior)
        }
    }

    private static func smooth(_ values: [Double], band: ClosedRange<Double>) -> [Double] {
        (0 ..< 24).map { hour in
            let left = values[(hour + 23) % 24]
            let right = values[(hour + 1) % 24]
            let mixed = 0.7 * values[hour] + 0.15 * left + 0.15 * right
            return min(max(mixed, band.lowerBound), band.upperBound)
        }
    }

    private static func absorptionHours(for meal: RheosMealOutcome, glucose: [RheosGlucosePoint]) -> Double? {
        guard let start = RheosStats.nearest(glucose, to: meal.date, within: 45 * 60) else { return nil }
        var best: Double?
        for step in 1 ... 8 {
            let at = meal.date.addingTimeInterval(Double(step) * 3600)
            guard let value = RheosStats.nearest(glucose, to: at, within: 30 * 60) else { continue }
            if abs(value - start) <= 20 {
                best = Double(step)
                break
            }
        }
        return best
    }
}

/// Closed-loop basal need from what the pump delivered. A closed loop hides a wrong basal: when it is
/// too low the loop adds temps and SMBs and glucose still looks fine. In a quiet hour (no carbs for
/// 4 hours, 8 after a fat-protein meal, no bolus for 3 hours, glucose within 70–180 and moving less
/// than 15 mg/dL) the insulin that was delivered is what that hour needed: scheduled basal where no
/// temp ran, the temps, and SMBs. Its ratio to the scheduled rate is the hour's basal factor.
/// An hour is used only when the older and the newer half of its days agree.
enum RheosDeliveredBasal {
    static let minimumDays = 5
    static let maximumDrift = 15.0
    static let range = 70.0 ... 180.0
    static let maximumDisagreement = 0.15

    /// One factor per clock hour, nil where the data are thin or disagree. Not clamped to a band.
    static func factors(dataset: RheosDataset, scheduledBasal: [Double], calendar: Calendar) -> [Double?] {
        var result = [Double?](repeating: nil, count: 24)
        guard scheduledBasal.count == 24, scheduledBasal.allSatisfy({ $0.isFinite && $0 > 0 }) else { return result }
        let temps = dataset.insulin
            .filter { $0.kind == "tempBasal" && $0.rate != nil && ($0.minutes ?? 0) > 0 }
            .sorted { $0.date < $1.date }
        guard !temps.isEmpty else { return result }
        // A newer temp ends the one before it, as on the pump.
        var spans: [(start: Date, end: Date, rate: Double)] = []
        for (index, temp) in temps.enumerated() {
            var end = temp.date.addingTimeInterval((temp.minutes ?? 0) * 60)
            if index + 1 < temps.count { end = min(end, temps[index + 1].date) }
            if end > temp.date { spans.append((temp.date, end, max(0, temp.rate ?? 0))) }
        }
        var smbByHour: [Date: Double] = [:]
        for smb in dataset.insulin where smb.kind == "smb" {
            if let key = calendar.dateInterval(of: .hour, for: smb.date)?.start {
                smbByHour[key, default: 0] += smb.units
            }
        }
        let boluses = dataset.insulin.filter { $0.kind == "bolus" }
        let glucose = dataset.glucose.sorted { $0.date < $1.date }
        guard let first = glucose.first?.date, let last = glucose.last?.date,
              var hourStart = calendar.dateInterval(of: .hour, for: first)?.start
        else { return result }
        var byHour = [[(day: Date, ratio: Double)]](repeating: [], count: 24)
        var glucoseCursor = 0
        var spanCursor = 0
        while hourStart.addingTimeInterval(3600) <= last {
            let start = hourStart
            let end = hourStart.addingTimeInterval(3600)
            hourStart = end
            while glucoseCursor < glucose.count, glucose[glucoseCursor].date < start { glucoseCursor += 1 }
            var values: [Double] = []
            var index = glucoseCursor
            while index < glucose.count, glucose[index].date < end {
                values.append(glucose[index].mgdl)
                index += 1
            }
            guard values.count >= 8, let low = values.min(), let high = values.max(),
                  range.contains(low), range.contains(high),
                  abs(values[values.count - 1] - values[0]) <= maximumDrift
            else { continue }
            let mealNearby = dataset.meals.contains { meal in
                guard meal.carbs >= 1 || meal.fat + meal.protein > 0 else { return false }
                let window: TimeInterval = meal.fat + meal.protein > 20 ? 8 * 3600 : 4 * 3600
                return meal.date < end && meal.date > start.addingTimeInterval(-window)
            }
            guard !mealNearby else { continue }
            guard !boluses.contains(where: { $0.date < end && $0.date > start.addingTimeInterval(-3 * 3600) }) else { continue }
            let hour = calendar.component(.hour, from: start)
            let scheduled = scheduledBasal[hour]
            while spanCursor < spans.count, spans[spanCursor].end <= start { spanCursor += 1 }
            var covered: TimeInterval = 0
            var delivered = 0.0
            var spanIndex = spanCursor
            while spanIndex < spans.count, spans[spanIndex].start < end {
                let span = spans[spanIndex]
                let overlap = min(span.end, end).timeIntervalSince(max(span.start, start))
                if overlap > 0 {
                    covered += overlap
                    delivered += span.rate * overlap / 3600
                }
                spanIndex += 1
            }
            delivered += scheduled * max(0, 3600 - covered) / 3600
            delivered += smbByHour[start] ?? 0
            byHour[hour].append((calendar.startOfDay(for: start), min(3, delivered / scheduled)))
        }
        for hour in 0 ..< 24 {
            let rows = byHour[hour].sorted { $0.day < $1.day }
            guard Set(rows.map(\.day)).count >= minimumDays,
                  let newestDay = rows.last?.day,
                  let median = RheosStats.weightedMedian(rows.map {
                      (value: $0.ratio, weight: RheosReference.recencyWeight($0.day, newest: newestDay))
                  })
            else { continue }
            let half = rows.count / 2
            guard let older = RheosStats.median(rows.prefix(half).map(\.ratio)),
                  let newer = RheosStats.median(rows.suffix(rows.count - half).map(\.ratio)),
                  abs(older - newer) <= maximumDisagreement
            else { continue }
            let count = Double(rows.count)
            result[hour] = (count * median + 3) / (count + 3)
        }
        return result
    }
}

extension RheosDeliveredBasal {
    /// Temps as the pump ran them: a newer temp ends the one before it.
    static func spans(_ insulin: [RheosInsulinEvent]) -> [(start: Date, end: Date, rate: Double)] {
        let temps = insulin
            .filter { $0.kind == "tempBasal" && $0.rate != nil && ($0.minutes ?? 0) > 0 }
            .sorted { $0.date < $1.date }
        var spans: [(start: Date, end: Date, rate: Double)] = []
        for (index, temp) in temps.enumerated() {
            var end = temp.date.addingTimeInterval((temp.minutes ?? 0) * 60)
            if index + 1 < temps.count { end = min(end, temps[index + 1].date) }
            if end > temp.date { spans.append((temp.date, end, max(0, temp.rate ?? 0))) }
        }
        return spans
    }

    /// Insulin the loop delivered on its own per calendar day: scheduled basal where no temp ran,
    /// the temps, and SMBs. Manual boluses are left out. Only days with glucose for most of the day
    /// and at least 24 temps count, so a day without loop data is not read as a low need.
    static func dailyAutomatic(dataset: RheosDataset, scheduledBasal: [Double], calendar: Calendar) -> [Date: Double] {
        guard scheduledBasal.count == 24, scheduledBasal.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return [:] }
        let runs = Self.spans(dataset.insulin)
        guard !runs.isEmpty else { return [:] }
        var glucoseCount: [Date: Int] = [:]
        for point in dataset.glucose where point.mgdl > 0 {
            glucoseCount[calendar.startOfDay(for: point.date), default: 0] += 1
        }
        var tempCount: [Date: Int] = [:]
        for span in runs {
            tempCount[calendar.startOfDay(for: span.start), default: 0] += 1
        }
        var smbByDay: [Date: Double] = [:]
        for smb in dataset.insulin where smb.kind == "smb" {
            smbByDay[calendar.startOfDay(for: smb.date), default: 0] += smb.units
        }
        var result: [Date: Double] = [:]
        var spanCursor = 0
        for day in glucoseCount.keys.sorted() {
            guard (glucoseCount[day] ?? 0) >= 200, (tempCount[day] ?? 0) >= 24,
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            var total = smbByDay[day] ?? 0
            var hourStart = day
            while hourStart < dayEnd {
                let hourEnd = min(hourStart.addingTimeInterval(3600), dayEnd)
                let hour = calendar.component(.hour, from: hourStart)
                while spanCursor < runs.count, runs[spanCursor].end <= hourStart { spanCursor += 1 }
                var covered: TimeInterval = 0
                var index = spanCursor
                while index < runs.count, runs[index].start < hourEnd {
                    let overlap = min(runs[index].end, hourEnd).timeIntervalSince(max(runs[index].start, hourStart))
                    if overlap > 0 {
                        covered += overlap
                        total += runs[index].rate * overlap / 3600
                    }
                    index += 1
                }
                total += scheduledBasal[hour] * max(0, hourEnd.timeIntervalSince(hourStart) - covered) / 3600
                hourStart = hourEnd
            }
            result[day] = total
        }
        return result
    }
}
