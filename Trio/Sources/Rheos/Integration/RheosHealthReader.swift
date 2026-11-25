import Foundation
import HealthKit

/// Read-only HealthKit queries for wearable context.
///
/// Authorization asks for read access only. Rheos does not write these types,
/// and this type never touches a pump or a CGM.
///
/// HealthKit background delivery is not real-time and is not used. Samples are
/// whatever has already synced (a finished workout, last night's sleep, the
/// day's step total). Callers must treat them as delayed context.
enum RheosHealthReader {
    static func requestReadAccess(store: HKHealthStore) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types = readTypes()
        guard !types.isEmpty else { return }
        do {
            try await store.requestAuthorization(toShare: Set<HKSampleType>(), read: types)
        } catch {
            debug(.service, "Rheos HealthKit read authorization failed: \(error)")
        }
    }

    static func read(store: HKHealthStore, now: Date = Date()) async -> (
        days: [RheosWearableDay],
        workouts: [RheosWorkout],
        sleep: [RheosSleepInterval]
    ) {
        guard HKHealthStore.isHealthDataAvailable() else { return ([], [], []) }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -RheosReference.retentionDays, to: now) ?? now
        let quantity = await quantities(store: store, start: start, end: now, calendar: calendar)
        let workouts = await workouts(store: store, start: start, end: now)
        let sleep = await sleep(store: store, start: start, end: now)
        var days = quantity
        add(workouts, to: &days, calendar: calendar)
        add(sleep, to: &days, calendar: calendar)
        return (days.sorted { $0.day < $1.day }, workouts, sleep)
    }

    static func readTypes() -> Set<HKObjectType> {
        var types = Set<HKObjectType>()
        let identifiers: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .respiratoryRate,
            .oxygenSaturation,
            .appleSleepingWristTemperature,
            .stepCount,
            .activeEnergyBurned,
            .bodyMass,
            .height,
            .bodyFatPercentage,
            .leanBodyMass
        ]
        for identifier in identifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        types.insert(HKObjectType.workoutType())
        // Beat-to-beat series the watch records with each HRV reading, for RMSSD during sleep.
        types.insert(HKSeriesType.heartbeat())
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        if let sex = HKCharacteristicType.characteristicType(forIdentifier: .biologicalSex) {
            types.insert(sex)
        }
        if let birth = HKCharacteristicType.characteristicType(forIdentifier: .dateOfBirth) {
            types.insert(birth)
        }
        return types
    }

    /// Latest body measurements already stored in Apple Health.
    /// Lean mass is not skeletal muscle. The caller labels that.
    static func readBody(store: HKHealthStore, now: Date = Date()) async -> RheosBodyInputs {
        guard HKHealthStore.isHealthDataAvailable() else { return RheosBodyInputs() }
        var inputs = RheosBodyInputs()
        if let birthday = try? store.dateOfBirthComponents(),
           let date = Calendar.current.date(from: birthday) {
            let years = Calendar.current.dateComponents([.year], from: date, to: now).year
            if let years, years > 0, years < 130 { inputs.ageYears = Double(years) }
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .female: inputs.sex = .female
            case .male: inputs.sex = .male
            case .other: inputs.sex = .other
            default: break
            }
        }
        inputs.weightKg = await latestKilograms(store: store, identifier: .bodyMass)
        if let meters = await latest(store: store, identifier: .height, unit: .meter()) {
            inputs.heightCm = meters * 100
        }
        if let fraction = await latest(store: store, identifier: .bodyFatPercentage, unit: .percent()) {
            inputs.bodyFatPercent = fraction <= 1.5 ? fraction * 100 : fraction
        }
        inputs.leanMassKg = await latestKilograms(store: store, identifier: .leanBodyMass)
        return inputs
    }

    private static func latestKilograms(store: HKHealthStore, identifier: HKQuantityTypeIdentifier) async -> Double? {
        await latest(store: store, identifier: identifier, unit: .gramUnit(with: .kilo))
    }

    private static func latest(
        store: HKHealthStore,
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                let quantity = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: quantity)
            }
            store.execute(query)
        }
    }

    private static func quantities(
        store: HKHealthStore,
        start: Date,
        end: Date,
        calendar: Calendar
    ) async -> [RheosWearableDay] {
        var byDay: [Date: RheosWearableDay] = [:]
        func day(_ date: Date) -> RheosWearableDay {
            let startOfDay = calendar.startOfDay(for: date)
            if byDay[startOfDay] == nil {
                byDay[startOfDay] = RheosWearableDay(day: startOfDay)
            }
            return byDay[startOfDay]!
        }

        if let type = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            let values = await statistics(store: store, type: type, unit: HKUnit.count().unitDivided(by: .minute()), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.heartRate = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            let values = await statistics(store: store, type: type, unit: HKUnit.count().unitDivided(by: .minute()), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.restingHeartRate = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            let values = await statistics(store: store, type: type, unit: HKUnit.secondUnit(with: .milli), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.hrvSDNN = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) {
            let values = await statistics(store: store, type: type, unit: HKUnit.count().unitDivided(by: .minute()), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.respiratoryRate = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            let values = await statistics(store: store, type: type, unit: HKUnit.percent(), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.oxygenSaturation = value * 100
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
            let values = await statistics(store: store, type: type, unit: HKUnit.degreeCelsius(), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.wristTemperature = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let values = await statistics(store: store, type: type, unit: .count(), options: .cumulativeSum, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.steps = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            let values = await statistics(store: store, type: type, unit: .kilocalorie(), options: .cumulativeSum, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.activeEnergy = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        return Array(byDay.values)
    }

    private static func statistics(
        store: HKHealthStore,
        type: HKQuantityType,
        unit: HKUnit,
        options: HKStatisticsOptions,
        start: Date,
        end: Date,
        calendar: Calendar
    ) async -> [Date: Double] {
        await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let anchor = calendar.startOfDay(for: start)
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                options: options,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, _ in
                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let quantity = options.contains(.cumulativeSum) ? statistics.sumQuantity() : statistics.averageQuantity()
                    if let quantity {
                        values[calendar.startOfDay(for: statistics.startDate)] = quantity.doubleValue(for: unit)
                    }
                }
                resumed.resume(continuation, returning: values)
            }
            store.execute(query)
        }
    }

    private static func workouts(store: HKHealthStore, start: Date, end: Date) async -> [RheosWorkout] {
        await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let workouts = (samples as? [HKWorkout])?.map { workout -> RheosWorkout in
                    let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
                    let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate)
                    let energy = energyType.flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .kilocalorie()) }
                    let heart = heartType.flatMap {
                        workout.statistics(for: $0)?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    }
                    return RheosWorkout(
                        id: workout.uuid.uuidString,
                        activity: activityName(workout.workoutActivityType),
                        start: workout.startDate,
                        durationMinutes: workout.duration / 60,
                        averageHeartRate: heart,
                        activeEnergy: energy
                    )
                } ?? []
                resumed.resume(continuation, returning: workouts)
            }
            store.execute(query)
        }
    }

    private static func sleep(store: HKHealthStore, start: Date, end: Date) async -> [RheosSleepInterval] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let intervals = (samples as? [HKCategorySample])?.compactMap { sample -> RheosSleepInterval? in
                    let stage = sleepStage(sample.value)
                    guard stage != "inBed", stage != "awake" else { return nil }
                    return RheosSleepInterval(
                        id: sample.uuid.uuidString,
                        start: sample.startDate,
                        end: sample.endDate,
                        stage: stage
                    )
                } ?? []
                resumed.resume(continuation, returning: intervals)
            }
            store.execute(query)
        }
    }

    private static func add(_ workouts: [RheosWorkout], to days: inout [RheosWearableDay], calendar: Calendar) {
        for workout in workouts {
            let key = calendar.startOfDay(for: workout.start)
            if let index = days.firstIndex(where: { calendar.startOfDay(for: $0.day) == key }) {
                days[index].workoutMinutes = (days[index].workoutMinutes ?? 0) + workout.durationMinutes
            } else {
                var day = RheosWearableDay(day: key)
                day.workoutMinutes = workout.durationMinutes
                days.append(day)
            }
        }
    }

    private static func add(_ sleep: [RheosSleepInterval], to days: inout [RheosWearableDay], calendar: Calendar) {
        for interval in sleep {
            let key = calendar.startOfDay(for: interval.start)
            let hours = interval.end.timeIntervalSince(interval.start) / 3600
            guard hours > 0 else { continue }
            if let index = days.firstIndex(where: { calendar.startOfDay(for: $0.day) == key }) {
                days[index].sleepHours = (days[index].sleepHours ?? 0) + hours
            } else {
                var day = RheosWearableDay(day: key)
                day.sleepHours = hours
                days.append(day)
            }
        }
    }

    private static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Laufen"
        case .cycling: return "Radfahren"
        case .walking: return "Gehen"
        case .traditionalStrengthTraining: return "Krafttraining"
        case .functionalStrengthTraining: return "Functional Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .swimming: return "Schwimmen"
        case .yoga: return "Yoga"
        default: return "Workout \(type.rawValue)"
        }
    }

    /// Recent watch/phone steps. `feedFresh` is false when nothing arrived in the last 20 minutes.
    static func recentSteps(store: HKHealthStore, now: Date) async -> RheosStepActivity.Windows {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return RheosStepActivity.Windows(steps5: 0, steps15: 0, steps30: 0, steps60: 0, feedFresh: false)
        }
        let start = now.addingTimeInterval(-60 * 60)
        let samples: [HKQuantitySample] = await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                resumed.resume(continuation, returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
        func total(minutes: Double) -> Int {
            let cut = now.addingTimeInterval(-minutes * 60)
            let sum = samples.filter { $0.endDate >= cut }.reduce(0.0) { partial, sample in
                partial + sample.quantity.doubleValue(for: .count())
            }
            return Int(sum.rounded())
        }
        let newest = samples.map(\.endDate).max()
        let fresh = newest.map { now.timeIntervalSince($0) <= 20 * 60 } ?? false
        return RheosStepActivity.Windows(
            steps5: total(minutes: 5),
            steps15: total(minutes: 15),
            steps30: total(minutes: 30),
            steps60: total(minutes: 60),
            feedFresh: fresh && !samples.isEmpty
        )
    }

    static func recentHeartRate(store: HKHealthStore, now: Date) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        let start = now.addingTimeInterval(-15 * 60)
        let samples: [HKQuantitySample] = await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                resumed.resume(continuation, returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let values = samples.map { $0.quantity.doubleValue(for: unit) }.filter { $0 > 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func sleepStage(_ value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: return "inBed"
        case .asleepUnspecified: return "asleep"
        case .awake: return "awake"
        case .asleepCore: return "core"
        case .asleepDeep: return "deep"
        case .asleepREM: return "rem"
        default: return "other"
        }
    }
}

/// Nights for the recovery score, Bevel-style: one sleep window per night, and heart rate, HRV,
/// breathing rate, wrist temperature and blood oxygen only from inside that window.
extension RheosHealthReader {
    static let nightCacheKey = "rheos.nights.v1"
    static let nightFullReadKey = "rheos.nights.fullRead"
    /// Beat-to-beat series read per night; the watch records a few per night.
    static let seriesPerNight = 8

    /// The nights of the last `RheosRecovery.historyDays`. Older nights come from a cache, so the
    /// full history is read from Health once and then checked once a day; in between only the last
    /// days are read. The last three nights are measured again each time because the watch syncs
    /// late, and a night of the last week without heart data is retried at the daily check.
    static func nights(store: HKHealthStore, now: Date = Date(), calendar: Calendar = .current) async -> [RheosNight] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let defaults = UserDefaults.standard
        let earliest = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -RheosRecovery.historyDays, to: now) ?? now)
        var byDay: [Date: RheosNight] = [:]
        for night in loadNights(defaults) where night.day >= earliest {
            byDay[night.day] = night
        }
        let today = calendar.startOfDay(for: now)
        let fresh = calendar.date(byAdding: .day, value: -3, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let full = byDay.isEmpty || now.timeIntervalSince1970 - defaults.double(forKey: nightFullReadKey) > 24 * 3600
        let readFrom = full ? earliest.addingTimeInterval(-86400) : today.addingTimeInterval(-5 * 86400)
        let samples = await sleepSamples(store: store, start: readFrom, end: now)
        // A locked iPhone reads nothing from Health; the cache stays as it is.
        guard !samples.isEmpty else { return byDay.values.sorted { $0.day < $1.day } }
        var measured = 0
        var current: Set<Date> = []
        let windows = RheosSleepNights.windows(samples, calendar: calendar)
            .filter { $0.day >= (full ? earliest : fresh) }
        // Newest first, so a first run that is cut short already has the nights that matter.
        for window in windows.reversed() {
            current.insert(window.day)
            if let old = byDay[window.day],
               abs(old.start.timeIntervalSince(window.start)) < 120,
               abs(old.end.timeIntervalSince(window.end)) < 120,
               window.day < fresh,
               old.sleepingHeartRate != nil || old.hrvSDNN != nil || window.day < week {
                continue
            }
            byDay[window.day] = await measure(window, store: store)
            measured += 1
            if measured.isMultiple(of: 15) { saveNights(Array(byDay.values), defaults: defaults) }
        }
        // A full read also drops nights that are no longer in Health; a short read keeps the older ones.
        let result = byDay.values
            .filter { !full || current.contains($0.day) }
            .sorted { $0.day < $1.day }
        saveNights(result, defaults: defaults)
        if full { defaults.set(now.timeIntervalSince1970, forKey: nightFullReadKey) }
        return result
    }

    private static func measure(_ window: RheosSleepNights.Window, store: HKHealthStore) async -> RheosNight {
        var night = RheosNight(
            day: window.day,
            start: window.start,
            end: window.end,
            asleepHours: window.asleepHours,
            deepHours: window.deepHours,
            remHours: window.remHours,
            awakeHours: window.awakeHours
        )
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        night.sleepingHeartRate = await average(store, .heartRate, perMinute, window.start, window.end)
        night.hrvSDNN = await average(store, .heartRateVariabilitySDNN, HKUnit.secondUnit(with: .milli), window.start, window.end)
        night.respiratoryRate = await average(store, .respiratoryRate, perMinute, window.start, window.end)
        night.oxygenSaturation = await average(store, .oxygenSaturation, .percent(), window.start, window.end).map { $0 * 100 }
        // The watch stores one wrist temperature per night, dated around the sleep.
        night.wristTemperature = await average(
            store,
            .appleSleepingWristTemperature,
            .degreeCelsius(),
            window.start.addingTimeInterval(-2 * 3600),
            window.end.addingTimeInterval(2 * 3600)
        )
        night.hrvRMSSD = await rmssd(store: store, start: window.start, end: window.end)
        return night
    }

    private static func average(
        _ store: HKHealthStore,
        _ identifier: HKQuantityTypeIdentifier,
        _ unit: HKUnit,
        _ start: Date,
        _ end: Date
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                options: .discreteAverage
            ) { _, statistics, _ in
                resumed.resume(continuation, returning: statistics?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private static func rmssd(store: HKHealthStore, start: Date, end: Date) async -> Double? {
        let series: [HKHeartbeatSeriesSample] = await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let query = HKSampleQuery(
                sampleType: HKSeriesType.heartbeat(),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                limit: seriesPerNight,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                resumed.resume(continuation, returning: (samples as? [HKHeartbeatSeriesSample]) ?? [])
            }
            store.execute(query)
        }
        var values: [Double] = []
        for sample in series {
            let beats = await heartbeats(store: store, series: sample)
            if let value = RheosRecovery.rmssd(beats) { values.append(value) }
        }
        return RheosStats.median(values)
    }

    private static func heartbeats(store: HKHealthStore, series: HKHeartbeatSeriesSample) async -> [(time: Double, gap: Bool)] {
        await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let collector = BeatCollector()
            let query = HKHeartbeatSeriesQuery(heartbeatSeries: series) { _, time, gap, done, error in
                if error != nil {
                    resumed.resume(continuation, returning: collector.beats)
                    return
                }
                collector.beats.append((time: time, gap: gap))
                if done { resumed.resume(continuation, returning: collector.beats) }
            }
            store.execute(query)
        }
    }

    private static func sleepSamples(store: HKHealthStore, start: Date, end: Date) async -> [RheosSleepNights.Sample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let result = (samples as? [HKCategorySample])?.map { sample in
                    RheosSleepNights.Sample(
                        start: sample.startDate,
                        end: sample.endDate,
                        stage: sleepStage(sample.value),
                        source: sample.sourceRevision.source.bundleIdentifier
                    )
                } ?? []
                resumed.resume(continuation, returning: result)
            }
            store.execute(query)
        }
    }

    static func loadNights(_ defaults: UserDefaults = .standard) -> [RheosNight] {
        guard let data = defaults.data(forKey: nightCacheKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([RheosNight].self, from: data)) ?? []
    }

    private static func saveNights(_ nights: [RheosNight], defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(nights.sorted { $0.day < $1.day }) { defaults.set(data, forKey: nightCacheKey) }
    }
}

private final class BeatCollector: @unchecked Sendable {
    var beats: [(time: Double, gap: Bool)] = []
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume<T>(_ continuation: CheckedContinuation<T, Never>, returning value: T) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        if shouldResume {
            continuation.resume(returning: value)
        }
    }
}
