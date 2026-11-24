import HandyFreiDrivers
import HealthKit
import SwiftUI
import Trio
import UserNotifications
import WatchConnectivity
import WatchKit

/// Handy-frei on the watch. One start, sensor and pump together. No patch stop and no sensor activation.
struct HandyFreiWatchView: View {
    @Bindable var state: WatchState
    @State private var showingAdjustments = false
    @State private var showingTraining = false
    @State private var sportTarget = true
    @State private var customTarget = 110.0
    @State private var customMinutes = 60.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.handyFreiRunning ? "Handy-frei aktiv" : "Handy-frei")
                    .font(.headline)
                Text(state.handyFreiStatus)
                    .font(.footnote)
                if !state.handyFreiLoopLine.isEmpty, state.handyFreiLoopLine != state.handyFreiStatus {
                    Text(state.handyFreiLoopLine)
                        .font(.footnote)
                }
                if !state.handyFreiAlarm.isEmpty {
                    Text(state.handyFreiAlarm)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if state.handyFreiRunning, state.handyFreiYielded {
                    Text("Eine andere App hat ein Training gestartet. Handy-frei pausiert, die Pumpe fällt auf ihr Basal zurück.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Handy-frei-Workout wieder starten") {
                        Task { await HandyFreiSession.shared.resumeAfterForeignWorkout(state) }
                    }
                }
                if state.handyFreiRunning, let hold = state.handyFreiHoldUntil {
                    Text("Vorsicht bis \(hold.formatted(date: .omitted, time: .shortened)): Die Kopie war beim Start alt. Kein SMB und kein Extra-Basal, Absenken läuft weiter.")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                    Button("iPhone hat seit der Kopie nichts dosiert") {
                        HandyFreiSession.shared.clearInsulinHold(state)
                    }
                }
                if !state.handyFreiRunning {
                    Button("Handy-frei aktivieren") {
                        state.activateHandyFrei()
                    }
                }
                if state.handyFreiRunning {
                    Button("Erneut versuchen") {
                        state.restartHandyFreiFromCache()
                    }
                }
                Button("Handy-frei neu starten") {
                    state.restartHandyFreiFromCache()
                }
                Button("Handy-frei beenden") {
                    state.stopHandyFrei()
                }
                Button("Mahlzeiten") {
                    state.showingMealPresets = true
                }
                if state.handyFreiRunning {
                    Button(showingAdjustments ? "Anpassungen schließen" : "Override und Temp-Ziel") {
                        showingAdjustments.toggle()
                    }
                    if showingAdjustments {
                        adjustments
                    }
                    if state.handyFreiTraining.isEmpty {
                        Button(showingTraining ? "Training schließen" : "Training starten") {
                            showingTraining.toggle()
                        }
                        if showingTraining {
                            trainingList
                        }
                    } else {
                        Text("Training: \(state.handyFreiTraining). Der Loop läuft im selben Workout weiter.")
                            .font(.footnote)
                        Button("Training beenden und speichern") {
                            Task { await HandyFreiSession.shared.endTraining(state) }
                        }
                    }
                }
                if let copied = state.handyFreiSnapshotAt {
                    let hours = Int(Date().timeIntervalSince(copied) / 3600)
                    Text(hours < 1
                        ? "Letzte Kopie: vor weniger als einer Stunde."
                        : "Letzte Kopie: vor \(hours) Stunden. Ein alter Pumpentoken kann abgelehnt werden.")
                        .font(.footnote)
                }
                Text("Start geht sofort, auch ohne iPhone. Die letzte Kopie reicht. Die Kopplung bleibt auf dem iPhone. Ist Bluetooth am iPhone noch an, hält das iPhone die Pumpe, bis die Verbindung fällt.")
                    .font(.footnote)
            }
            .padding()
        }
        .sheet(isPresented: $state.showingMealPresets) {
            MealPresetListView(state: state)
        }
    }

    private var trainingList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("watchOS erlaubt nur ein Workout. Hier gestartet, loopt Trio darin weiter und speichert das Training in Health. In der Workout-App gestartet, pausiert Handy-frei.")
                .font(.footnote)
            if HandyFreiLoop.savedTempTargets(state.handyFreiFiles).contains(where: { $0.name.lowercased() == "sport" }) {
                Toggle("Temp-Ziel „Sport“ dazu", isOn: $sportTarget)
                    .font(.footnote)
            }
            ForEach(HandyFreiTraining.all, id: \.name) { training in
                Button(training.name) {
                    showingTraining = false
                    Task { await HandyFreiSession.shared.startTraining(state, training, sportTarget: sportTarget) }
                }
            }
        }
    }

    private var adjustments: some View {
        let overrides = HandyFreiLoop.savedOverrides(state.handyFreiFiles)
        let targets = HandyFreiLoop.savedTempTargets(state.handyFreiFiles)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Override").font(.footnote)
            if overrides.isEmpty {
                Text("Keine Override-Vorlagen in der Kopie.").font(.footnote)
            }
            ForEach(overrides, id: \.name) { preset in
                Button(preset.indefinite ? "\(preset.name) \(Int(preset.percentage)) %" : "\(preset.name) \(Int(preset.percentage)) % \(Int(preset.durationMinutes)) min") {
                    HandyFreiSession.shared.startOverride(state, preset)
                }
            }
            Button("Override beenden") { HandyFreiSession.shared.stopOverride(state) }
            Text("Temp-Ziel").font(.footnote)
            ForEach(targets, id: \.name) { preset in
                Button("\(preset.name) \(Int(preset.target)) \(Int(preset.durationMinutes)) min") {
                    HandyFreiSession.shared.startTempTarget(state, name: preset.name, target: preset.target, minutes: max(15, Int(preset.durationMinutes)))
                }
            }
            Text("Eigenes Ziel \(Int(customTarget)) mg/dL, \(Int(customMinutes)) min")
                .font(.footnote)
                .focusable()
                .digitalCrownRotation($customTarget, from: 80, through: 180, by: 5, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
            Button("Dauer \(Int(customMinutes)) min") {
                customMinutes = customMinutes >= 120 ? 30 : customMinutes + 30
            }
            Button("Eigenes Temp-Ziel starten") {
                HandyFreiSession.shared.startTempTarget(state, name: "Eigenes", target: customTarget, minutes: Int(customMinutes))
            }
            Button("Temp-Ziel beenden") { HandyFreiSession.shared.stopTempTarget(state) }
        }
    }
}

struct MealPresetListView: View {
    @Bindable var state: WatchState

    var body: some View {
        List {
            if state.mealPresets.isEmpty {
                Text("Keine gespeicherten Mahlzeiten. Sie kommen mit der Kopie vom iPhone.")
                    .font(.footnote)
            }
            ForEach(state.mealPresets) { preset in
                Button {
                    state.stageMeal(preset)
                    state.showingMealPresets = false
                    state.mealNeedsBolus = true
                } label: {
                    VStack(alignment: .leading) {
                        Text(preset.name)
                        Text("\(Int(preset.carbs.rounded())) g · F \(Int(preset.fat.rounded())) · E \(Int(preset.protein.rounded()))")
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Mahlzeiten")
    }
}

extension WatchState {
    /// Phone already confirmed Bluetooth is off, or the phone can no longer be reached.
    func startHandyFrei() {
        HandyFreiSession.shared.start(self)
    }

    /// Starts at once. A reachable phone sends a fresh snapshot and pauses its loop. Otherwise the last copy is used.
    func activateHandyFrei() {
        guard !handyFreiRunning else { return }
        handyFreiStatus = "Handy-frei wird aktiviert…"
        handyFreiActivationRefused = false
        guard let session, session.activationState == .activated, session.isReachable else {
            startHandyFrei()
            return
        }
        session.sendMessage(["handyFreiActivate": true], replyHandler: nil, errorHandler: { _ in
            DispatchQueue.main.async {
                guard !self.handyFreiRunning else { return }
                self.handyFreiStatus = "iPhone nicht erreicht. Start mit der letzten Kopie."
                self.startHandyFrei()
            }
        })
        // The copy comes as a file of several hundred KB. Over Bluetooth that can take a while,
        // so the watch waits up to 45 seconds before it starts from the copy it already has.
        handyFreiStatus = "Handy-frei wird aktiviert. Warte auf die Kopie vom iPhone (bis 45 s)…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            // The iPhone said why it cannot hand over. That reason stays on screen.
            guard !self.handyFreiRunning, !self.handyFreiActivationRefused else { return }
            self.handyFreiStatus = "Kein neuer Schnappschuss. Start mit der letzten Kopie."
            self.startHandyFrei()
        }
    }

    /// Restarts from the keys and profile already on the watch. Does not ask the iPhone.
    func restartHandyFreiFromCache() {
        HandyFreiSession.shared.restartFromCache(self)
    }

    /// One tap. Starts only after the phone confirms Bluetooth is off, or when the phone is unreachable.
    func requestHandyFrei() {
        activateHandyFrei()
    }

    func stopHandyFrei() {
        HandyFreiSession.shared.finish(self)
    }
}

/// Owns the workout, the Libre session and the pump commands for one stretch.
final class HandyFreiSession {
    static let shared = HandyFreiSession()
    private var log: [[String: Any]] = []
    private var deliveries: [HandyFreiLoop.Delivery] = []
    private var readings: [(date: Date, mgdl: Int)] = []
    private var directions: [Double: String] = [:]
    private var ackedLogIDs = Set(UserDefaults.standard.stringArray(forKey: "handyfrei.ackedLogIDs") ?? [])
    private var lastOutboxFlush = Date.distantPast
    /// Bumped when the stretch ends so a glucose task already in flight cannot dose afterwards.
    private var doseEpoch = 0
    private var dosing = false
    private var lastDose = Date.distantPast
    private var pumpRetries = 0
    private var sensorRetries = 0
    private var workoutRestarts = 0
    private var lastWorkoutRestart = Date.distantPast
    private var replacingSensor = false
    private var sensorGeneration = 0
    private var lastPacketAt: Date?
    private var lastStallAttempt = Date.distantPast
    private var stallAttempts = 0
    private var backoffTask: Task<Void, Never>?
    private var glucoseAgeTask: Task<Void, Never>?
    private var loopWatchTask: Task<Void, Never>?
    private var autosensTask: Task<Void, Never>?
    private var lastLoopAt = Date.distantPast
    private var doseStartedAt: Date?
    private var bolusUncertain = false
    /// Under 10 % battery: the loop only lowers insulin.
    private var lowBattery = false
    /// Another app started a workout. Restarting ours would end that training, so the watch waits
    /// until Trio is opened again.
    private var yieldedToForeignWorkout = false
    private var determining = false
    private var lastSuccess = Date.distantPast
    private var lastReason = "Loop wartet auf den ersten Wert."
    private var lastIOB = 0.0
    private var lastCOB = 0.0
    /// Bumped when a meal is saved so a loop that started earlier cannot write COB 0 back over it.
    private var mealRevision = 0
    private var active = false
    private var carbs: [HandyFreiDisk.Carb] = []
    private var address = ""
    private var pin = Data()
    private var phase5 = Data()
    private var pumpSerial = ""
    private var sessionToken = ""
    private var backupToken = ""
    private var sensorPeripheralID = ""

    func start(_ state: WatchState) {
        bind(state)
        guard !state.handyFreiRunning else { return }
        // A resume after a crash or relaunch continues the same stretch. Only a new start checks the copy age.
        let resuming = HandyFreiDisk.wasActive()
        state.handyFreiRunning = true
        HandyFreiAlarm.requestPermission()
        yieldedToForeignWorkout = false
        state.handyFreiYielded = false
        doseEpoch += 1
        backoffTask?.cancel()
        backoffTask = nil
        glucoseAgeTask?.cancel()
        glucoseAgeTask = nil
        loopWatchTask?.cancel()
        loopWatchTask = nil
        autosensTask?.cancel()
        autosensTask = nil
        dosing = false
        doseStartedAt = nil
        bolusUncertain = false
        determining = false
        pumpRetries = 0
        sensorRetries = 0
        workoutRestarts = 0
        replacingSensor = false
        lastPacketAt = nil
        lastStallAttempt = .distantPast
        stallAttempts = 0
        let epoch = doseEpoch
        state.handyFreiAlarm = ""
        active = true
        log = []
        deliveries = []
        readings = []
        carbs = []
        lastSuccess = .distantPast
        lastDose = .distantPast
        lastReason = "Loop wartet auf den ersten Wert."
        HandyFreiDisk.restore(into: state, session: self)
        if !resuming { armInsulinHold(state) }
        state.handyFreiHoldUntil = insulinHoldUntil
        self.seedSnapshotGlucose(state)
        self.showSnapshotTotals(state)
        HandyFreiDisk.save(session: self, urgent: true)
        self.scheduleRefresh()
        lastLoopAt = lastSuccess == .distantPast ? Date() : lastSuccess
        address = state.handyFreiBleAddress
        pin = Data(base64Encoded: state.handyFreiBlePIN) ?? Data()
        phase5 = Data(base64Encoded: state.handyFreiPhase5) ?? Data()
        pumpSerial = state.handyFreiPumpSerial
        sessionToken = state.handyFreiSessionToken
        backupToken = state.handyFreiBackupToken
        sensorPeripheralID = state.handyFreiSensorPeripheralID
        HandyFreiMedtrumLink.shared.onConnectionLost = { [weak self] in
            DispatchQueue.main.async {
                guard let self, state.handyFreiRunning else { return }
                Task { await self.restorePump(state) }
            }
        }
        Task { @MainActor in
            guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
            self.startLoopWatch(state, epoch: epoch)
            self.startAutosensRefresh(state, epoch: epoch)
            let allowed = await HandyFreiWorkout.shared.prepare { endReason in
                DispatchQueue.main.async {
                    guard state.handyFreiRunning else { return }
                    Task { await self.keepAwake(state, reason: endReason) }
                }
            }
            guard allowed else {
                await MainActor.run {
                    self.giveUpOrRetry(state, "HealthKit nicht erlaubt.")
                }
                return
            }
            guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
            let missing = self.missingKeys()
            if !missing.isEmpty {
                let text = "Schlüssel fehlen: \(missing.joined(separator: ", ")). iPhone in die Nähe, Trio dort öffnen, dann Handy-frei beenden und neu aktivieren."
                await self.mark(state, text)
                self.giveUpOrRetry(state, text)
                return
            }
            do {
                try await self.openPump(state, attempt: 1)
                guard state.handyFreiRunning, epoch == self.doseEpoch else {
                    HandyFreiMedtrumLink.shared.stop()
                    return
                }
                try await self.openSensor(state)
                self.startGlucoseWatch(state, epoch: epoch)
            } catch {
                let text = Self.failureText(stage: "Start", error: error)
                await self.mark(state, text)
                await MainActor.run {
                    guard state.handyFreiRunning else { return }
                    self.giveUpOrRetry(state, text)
                }
            }
        }
    }

    private static let holdKey = "handyfrei.insulinHoldUntil"

    /// Doses the iPhone gave after the last copy are not in it. A new start from a copy older than
    /// 30 minutes therefore holds extra insulin for four hours: no SMB and no temp above basal,
    /// the same limits as Trio's Low Glucose Suspend. Zero and low temps still run.
    private func armInsulinHold(_ state: WatchState) {
        let age = Date().timeIntervalSince(state.handyFreiSnapshotAt ?? .distantPast)
        guard age > 30 * 60 else {
            UserDefaults.standard.removeObject(forKey: Self.holdKey)
            return
        }
        let until = Date().addingTimeInterval(4 * 3600)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.holdKey)
        let minutes = age > 24 * 3600 ? "über 24 h" : "\(Int(age / 60)) min"
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "stage",
            "text": "Kopie \(minutes) alt. Bis \(Self.clockMinute(until)) kein SMB und kein Extra-Basal."
        ])
    }

    var insulinHoldUntil: Date? {
        let raw = UserDefaults.standard.double(forKey: Self.holdKey)
        guard raw > 0 else { return nil }
        let until = Date(timeIntervalSince1970: raw)
        return until > Date() ? until : nil
    }

    /// A hand-off copy: the iPhone paused its loop before it sent it, so it holds every iPhone dose.
    func freshCopyArrived(_ state: WatchState) {
        UserDefaults.standard.removeObject(forKey: Self.holdKey)
        state.handyFreiHoldUntil = nil
    }

    /// The user confirms the iPhone gave no insulin after the copy.
    func clearInsulinHold(_ state: WatchState) {
        UserDefaults.standard.removeObject(forKey: Self.holdKey)
        state.handyFreiHoldUntil = nil
        log.append(["date": Date().timeIntervalSince1970, "kind": "stage", "text": "Vorsicht aufgehoben."])
        HandyFreiDisk.save(session: self, urgent: true)
    }

    /// Runs a training in Handy-frei's own workout, so the loop keeps running during sport.
    /// The saved temp target named "Sport" is started with it when asked.
    @MainActor func startTraining(_ state: WatchState, _ training: HandyFreiTraining, sportTarget: Bool) async {
        guard state.handyFreiRunning else { return }
        let started = await HandyFreiWorkout.shared.startTraining(training.activity, name: training.name, outdoor: training.outdoor)
        guard started else {
            let detail = HandyFreiWorkout.shared.lastFailure
            state.handyFreiStatus = detail.isEmpty ? "Training nicht gestartet." : "Training nicht gestartet. \(detail)"
            if !HandyFreiWorkout.shared.isRunning { await keepAwake(state, reason: "Training nicht gestartet") }
            return
        }
        yieldedToForeignWorkout = false
        state.handyFreiYielded = false
        state.handyFreiTraining = training.name
        log.append(["date": Date().timeIntervalSince1970, "kind": "stage", "text": "Training \(training.name) gestartet."])
        if sportTarget,
           let preset = HandyFreiLoop.savedTempTargets(state.handyFreiFiles).first(where: { $0.name.lowercased() == "sport" })
        {
            startTempTarget(state, name: preset.name, target: preset.target, minutes: max(15, Int(preset.durationMinutes)))
        }
        HandyFreiDisk.save(session: self)
    }

    /// The other app's training is over. Starting Handy-frei's workout again would end it otherwise.
    @MainActor func resumeAfterForeignWorkout(_ state: WatchState) async {
        yieldedToForeignWorkout = false
        state.handyFreiYielded = false
        await keepAwake(state, reason: "Nach dem Training in einer anderen App")
    }

    @MainActor func endTraining(_ state: WatchState) async {
        let name = state.handyFreiTraining
        let back = await HandyFreiWorkout.shared.endTraining()
        state.handyFreiTraining = ""
        log.append(["date": Date().timeIntervalSince1970, "kind": "stage", "text": "Training \(name) beendet und in Health gespeichert."])
        state.handyFreiStatus = "Training \(name) gespeichert. Handy-frei läuft weiter."
        if !back { await keepAwake(state, reason: "Nach dem Training") }
        HandyFreiDisk.save(session: self)
    }

    /// No insulin once the newest reading is older than 12 minutes. The session stays up.
    private func startLoopWatch(_ state: WatchState, epoch: Int) {
        loopWatchTask?.cancel()
        loopWatchTask = Task { @MainActor in await self.watchLoop(state, epoch: epoch) }
    }

    /// Keeps the phone heartbeat. Autosens itself runs inside every loop.
    private func startAutosensRefresh(_ state: WatchState, epoch: Int) {
        autosensTask?.cancel()
        autosensTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while state.handyFreiRunning, epoch == self.doseEpoch, !Task.isCancelled {
                self.scheduleRefresh()
                await MainActor.run {
                    state.reportHandyFreiHeartbeat()
                    self.flushOutbox(final: false)
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func startOverride(_ state: WatchState, _ preset: HandyFreiLoop.SavedOverride) {
        HandyFreiLoop.startOverride(&state.handyFreiFiles, preset, now: Date())
        log.append([
            "date": Date().timeIntervalSince1970, "kind": "override", "name": preset.name,
            "percentage": preset.percentage, "minutes": Int(preset.durationMinutes),
            "text": "Override \(preset.name) \(Int(preset.percentage)) %"
        ])
        state.handyFreiStatus = "Override \(preset.name) aktiv."
        HandyFreiDisk.save(session: self)
    }

    func stopOverride(_ state: WatchState) {
        HandyFreiLoop.stopOverride(&state.handyFreiFiles, now: Date())
        log.append(["date": Date().timeIntervalSince1970, "kind": "overrideStop", "text": "Override aus"])
        state.handyFreiStatus = "Override beendet."
        HandyFreiDisk.save(session: self)
    }

    func startTempTarget(_ state: WatchState, name: String, target: Double, minutes: Int) {
        HandyFreiLoop.startTempTarget(&state.handyFreiFiles, name: name, target: target, minutes: minutes, halfBasal: 160, now: Date())
        log.append([
            "date": Date().timeIntervalSince1970, "kind": "tempTarget", "name": name,
            "target": target, "minutes": minutes, "text": "Temp-Ziel \(name) \(Int(target)) \(minutes) min"
        ])
        state.handyFreiStatus = "Temp-Ziel \(Int(target)) für \(minutes) min."
        HandyFreiDisk.save(session: self)
    }

    func stopTempTarget(_ state: WatchState) {
        HandyFreiLoop.stopTempTarget(&state.handyFreiFiles, now: Date())
        log.append(["date": Date().timeIntervalSince1970, "kind": "tempTargetStop", "text": "Temp-Ziel aus"])
        state.handyFreiStatus = "Temp-Ziel beendet."
        HandyFreiDisk.save(session: self)
    }

    /// Keeps the countdown moving, and starts the loop when it reaches zero.
    @MainActor private func watchLoop(_ state: WatchState, epoch: Int) async {
        while state.handyFreiRunning, epoch == doseEpoch, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard state.handyFreiRunning, epoch == doseEpoch, !Task.isCancelled else { return }
            let stuck = await MainActor.run { () -> Bool in
                guard let started = self.doseStartedAt, self.dosing else { return false }
                return Date().timeIntervalSince(started) > 70
            }
            if stuck {
                HandyFreiMedtrumLink.shared.cancelPendingWrite()
                await MainActor.run {
                    self.dosing = false
                    self.doseStartedAt = nil
                    self.bolusUncertain = true
                    let line = "\(Self.clock()) Pumpe: Zeitüberschreitung. Loop läuft weiter. SMB wartet auf den Verlauf."
                    state.handyFreiStatus = line
                    state.handyFreiLoopLine = line
                }
            }
            await MainActor.run {
                let remain = self.secondsUntilLoop()
                let quiet = Date().timeIntervalSince(self.lastLoopAt)
                let watchdog = quiet > 7 * 60 && !self.determining && !self.dosing
                state.handyFreiHoldUntil = self.insulinHoldUntil
                let sinceSuccess = Date().timeIntervalSince(self.lastSuccess)
                if self.lastSuccess != .distantPast, sinceSuccess > 20 * 60 {
                    HandyFreiAlarm.fire(
                        "handyfrei.loop",
                        every: 20 * 60,
                        title: "Loop läuft nicht",
                        body: "Letzter Loop auf der Uhr vor \(Int(sinceSuccess / 60)) min. Handy-frei öffnen."
                    )
                } else {
                    HandyFreiAlarm.reset("handyfrei.loop")
                }
                guard let last = self.readings.max(by: { $0.date < $1.date }) else {
                    if watchdog {
                        state.handyFreiStatus = "\(Self.clock()) Loop-Wächter: letzter Lauf vor \(Int(quiet / 60)) min. Noch kein Glukosewert."
                    }
                    return
                }
                if watchdog {
                    state.handyFreiStatus = "\(Self.clock()) Loop-Wächter: letzter Lauf vor \(Int(quiet / 60)) min, starte neu."
                    self.evaluate(state, mgdl: last.mgdl, appendReading: false, force: true)
                } else if remain > 0 {
                    self.showWaiting(state, mgdl: last.mgdl, remain: remain)
                } else {
                    self.evaluate(state, mgdl: last.mgdl, appendReading: false, force: false)
                }
            }
        }
    }

    private func seedSnapshotGlucose(_ state: WatchState) {
        guard readings.isEmpty else { return }
        readings = HandyFreiLoop.snapshotReadings(state.handyFreiFiles)
        if readings.count > 36 { readings.removeFirst(readings.count - 36) }
    }

    private func showSnapshotTotals(_ state: WatchState) {
        guard let mgdl = readings.max(by: { $0.date < $1.date })?.mgdl else { return }
        let outcome = tickNow(state)
        guard !outcome.failed else { return }
        lastIOB = outcome.iob
        lastCOB = outcome.cob
        state.iob = String(format: "%.1f", outcome.iob)
        state.cob = String(format: "%.0f", outcome.cob)
        state.handyFreiGlucose = mgdl
    }

    func recordCarbs(grams: Int, fat: Int = 0, protein: Int = 0, name: String = "", id: String = UUID().uuidString, date: Date, state: WatchState) {
        mealRevision += 1
        let revision = mealRevision
        let entry = HandyFreiDisk.Carb(
            id: id,
            date: date.timeIntervalSince1970,
            grams: Double(grams),
            fat: Double(fat),
            protein: Double(protein),
            name: name,
            isFPU: false,
            fpuID: (fat > 0 || protein > 0) ? id : nil
        )
        carbs.append(entry)
        var parent: [String: Any] = [
            "date": date.timeIntervalSince1970,
            "kind": "carb",
            "id": id,
            "grams": Double(grams),
            "fat": Double(fat),
            "protein": Double(protein),
            "name": name,
            "text": "\(name.isEmpty ? "Mahlzeit" : name) \(grams) g KH, \(fat) g Fett, \(protein) g Eiweiß"
        ]
        if fat > 0 || protein > 0 {
            parent["fpuID"] = id
        }
        log.append(parent)
        var fpuCount = 0
        let settings = HandyFreiLoop.mealSettings(state.handyFreiFiles)
        if settings.fpu, fat > 0 || protein > 0 {
            let future = FatProteinConversion.futureEntries(
                fat: NSDecimalNumber(value: fat).decimalValue,
                protein: NSDecimalNumber(value: protein).decimalValue,
                createdAt: date,
                actualDate: date,
                fpuID: id,
                adjustment: settings.adjustment,
                delayMinutes: settings.delay,
                intervalMinutes: settings.interval
            )
            fpuCount = future.count
            for item in future {
                let when = item.actualDate ?? date
                let child = HandyFreiDisk.Carb(
                    id: item.id ?? UUID().uuidString,
                    date: when.timeIntervalSince1970,
                    grams: NSDecimalNumber(decimal: item.carbs).doubleValue,
                    fat: 0,
                    protein: 0,
                    name: "FPU",
                    isFPU: true,
                    fpuID: id
                )
                carbs.append(child)
                log.append([
                    "date": when.timeIntervalSince1970,
                    "kind": "fpu",
                    "id": child.id,
                    "grams": child.grams,
                    "fat": 0.0,
                    "protein": 0.0,
                    "name": "FPU",
                    "fpuID": id,
                    "text": "FPU \(Int(child.grams)) g"
                ])
            }
        }
        prune()
        HandyFreiLoop.rememberCarbs(&state.handyFreiFiles, loopCarbs())
        HandyFreiDisk.save(session: self)
        let saved = "Mahlzeit \(Self.clockMinute(date)): \(grams) g KH + \(fpuCount) FPU-Einträge gespeichert"
        state.handyFreiStatus = saved
        state.handyFreiLoopLine = saved
        guard let mgdl = readings.max(by: { $0.date < $1.date })?.mgdl else { return }
        let outcome = tickNow(state)
        guard revision == mealRevision, !outcome.failed else { return }
        lastIOB = outcome.iob
        lastCOB = outcome.cob
        lastReason = outcome.reason
        state.iob = String(format: "%.1f", outcome.iob)
        state.cob = String(format: "%.0f", outcome.cob)
        state.handyFreiGlucose = mgdl
        state.handyFreiLoopLine = "\(saved) · COB \(state.cob ?? "0")"
    }

    private func startGlucoseWatch(_ state: WatchState, epoch: Int) {
        glucoseAgeTask?.cancel()
        let started = Date()
        glucoseAgeTask = Task { @MainActor in await self.watchGlucoseAge(state, epoch: epoch, started: started) }
    }

    @MainActor private func watchGlucoseAge(_ state: WatchState, epoch: Int, started: Date) async {
        while state.handyFreiRunning, epoch == doseEpoch, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard state.handyFreiRunning, epoch == doseEpoch else { return }
            let snapshot = await MainActor.run { () -> (date: Date, hasReading: Bool) in
                (self.readings.map(\.date).max() ?? started, !self.readings.isEmpty)
            }
            let newest = snapshot.date
            if snapshot.hasReading {
                let quiet = Date().timeIntervalSince(newest)
                if quiet > 5 * 60, Date().timeIntervalSince(lastStallAttempt) > 5 * 60 {
                    await reconnectStalledSensor(state, quietMinutes: Int(quiet / 60))
                }
            }
            let silent = Date().timeIntervalSince(newest)
            if silent > 20 * 60 {
                HandyFreiAlarm.fire(
                    "handyfrei.noGlucose",
                    every: 20 * 60,
                    title: "Kein Glukosewert",
                    body: "Seit \(Int(silent / 60)) min kein Wert vom Sensor. Kein neues Insulin."
                )
            } else {
                HandyFreiAlarm.reset("handyfrei.noGlucose")
            }
            guard silent > 12 * 60 else { continue }
            let files = await MainActor.run { state.handyFreiFiles }
            guard HandyFreiLoop.enactsInsulin(files) else { continue }
            await mark(state, "Glukose älter als 12 Minuten. Kein Insulin.")
            // The loop decides: only a temp above the scheduled basal is ended. A zero or low
            // temp keeps running out on the pump, as determine-basal does with stale glucose.
            let mustCancel = await MainActor.run { () -> Bool in
                if self.dosing || self.determining { return false }
                guard self.tickNow(state).cancelTemp else { return false }
                self.dosing = true
                return true
            }
            guard mustCancel else { continue }
            let sent = await deliverTemp(state, rate: 0, minutes: 0)
            await MainActor.run {
                if sent {
                    self.deliveries.append(HandyFreiLoop.Delivery(
                        kind: "temp", units: 0, minutes: 0, date: Date(), label: "Temp-Abbruch"
                    ))
                    self.log.append(["date": Date().timeIntervalSince1970, "kind": "temp", "units": 0.0, "minutes": 0])
                    HandyFreiDisk.save(session: self)
                }
                self.dosing = false
            }
        }
    }

    /// Restarts the workout as soon as it has ended. watchOS suspends a background app shortly after
    /// its workout ends, so a long wait here means the restart never runs. Only a session that ends
    /// again within a minute waits 5 seconds. If the restart fails, a notification asks to open Trio:
    /// in the foreground the next wake starts the workout again.
    @MainActor private func keepAwake(_ state: WatchState, reason: String) async {
        guard state.handyFreiRunning else { return }
        state.handyFreiTraining = HandyFreiWorkout.shared.trainingName ?? ""
        if HandyFreiWorkout.shared.isRunning { return }
        if reason == HandyFreiWorkout.foreignReason {
            yieldedToForeignWorkout = true
            log.append(["date": Date().timeIntervalSince1970, "kind": "stage", "text": "Workout an eine andere App abgegeben."])
            state.handyFreiStatus = "Training in einer anderen App. Handy-frei pausiert, die Pumpe fällt auf ihr Basal zurück. Nach dem Training Trio öffnen."
        }
        if yieldedToForeignWorkout {
            // Restarting here would end the other app's training. The user restarts it on the
            // Handy-frei screen once that training is over.
            state.handyFreiYielded = true
            if WKApplication.shared().applicationState != .active {
                HandyFreiAlarm.fire(
                    "handyfrei.workout",
                    every: 30 * 60,
                    title: "Handy-frei pausiert",
                    body: "Eine andere App hat ein Training gestartet, watchOS erlaubt nur eins. Nach dem Training Trio öffnen und das Workout wieder starten."
                )
            }
            return
        }
        if Date().timeIntervalSince(lastWorkoutRestart) < 60 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        guard state.handyFreiRunning, !HandyFreiWorkout.shared.isRunning else { return }
        lastWorkoutRestart = Date()
        workoutRestarts += 1
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "stage",
            "text": "Workout neu \(workoutRestarts): \(reason)"
        ])
        let allowed = await HandyFreiWorkout.shared.prepare { endReason in
            DispatchQueue.main.async {
                guard state.handyFreiRunning else { return }
                Task { await self.keepAwake(state, reason: endReason) }
            }
        }
        guard allowed, state.handyFreiRunning else {
            let detail = HandyFreiWorkout.shared.lastFailure
            log.append([
                "date": Date().timeIntervalSince1970,
                "kind": "stage",
                "text": detail.isEmpty ? "Workout nicht gestartet" : "Workout nicht gestartet: \(detail)"
            ])
            HandyFreiAlarm.fire(
                "handyfrei.workout",
                every: 10 * 60,
                title: "Handy-frei pausiert",
                body: "Die Uhr konnte das Workout nicht neu starten. Trio auf der Uhr öffnen, damit der Loop weiterläuft."
            )
            giveUpOrRetry(state, detail.isEmpty ? "Workout nicht gestartet." : "Workout nicht gestartet: \(detail)")
            return
        }
        HandyFreiAlarm.reset("handyfrei.workout")
        HandyFreiAlarm.clear("handyfrei.workout")
    }

    /// Three tries, then the phone takes the radio back. Reconnect uses the saved token. It does not pair again.
    @MainActor private func openPump(_ state: WatchState, attempt: Int) async throws {
        await mark(state, attempt == 1 ? "Pumpe: suche" : "Pumpe: erneut \(attempt)")
        do {
            HandyFreiMedtrumLink.shared.stop()
            try await HandyFreiMedtrumLink.shared.connect(
                pumpSerialBase64: pumpSerial,
                sessionTokenBase64: sessionToken,
                backupTokenBase64: backupToken
            )
            await mark(state, "Pumpe: verbunden")
            await mark(state, "Pumpe: Status lesen")
            try await HandyFreiMedtrumLink.shared.send(.readStatus)
            await mark(state, "Pumpe: Status gelesen")
            await mark(state, "Pumpe: Verlauf lesen")
            try await HandyFreiMedtrumLink.shared.send(.readHistory)
            await MainActor.run { self.adoptPumpReading(state) }
            await mark(state, "Pumpe: Verlauf gelesen")
            pumpRetries = 0
        } catch {
            HandyFreiMedtrumLink.shared.stop()
            guard attempt < 3, state.handyFreiRunning else { throw error }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try await openPump(state, attempt: attempt + 1)
        }
    }

    /// The synchronize reply has the latest completed bolus and reservoir. A bolus already
    /// in the snapshot within 10 minutes is not added again.
    private func adoptPumpReading(_ state: WatchState) {
        let link = HandyFreiMedtrumLink.shared
        if let units = link.lastReservoirUnits, units > 0 {
            state.handyFreiFiles["reservoir"] = String(units)
        }
        if let alarm = link.lastPatchAlarm, !alarm.isEmpty {
            state.handyFreiAlarm = "\(Self.clockMinute()) \(alarm)"
        }
        if let units = link.lastBolusUnits, units >= 0.05 {
            let already = deliveries.contains {
                $0.kind == "bolus" && abs($0.units - units) < 0.051 && Date().timeIntervalSince($0.date) < 10 * 60
            }
            if !already {
                deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: units, minutes: 0, date: Date(), label: "Bolus"))
                log.append([
                    "date": Date().timeIntervalSince1970,
                    "kind": "bolus",
                    "units": units,
                    "minutes": 0,
                    "text": "Bolus aus dem Pumpenverlauf"
                ])
                HandyFreiDisk.save(session: self)
            }
        }
    }

    /// The BLE link can stay "connected" while notifications stop. A new cached
    /// handshake uses the same phase-5 key. It does not re-pair or deactivate.
    @MainActor private func reconnectStalledSensor(_ state: WatchState, quietMinutes: Int) async {
        guard state.handyFreiRunning, !replacingSensor else { return }
        lastStallAttempt = Date()
        stallAttempts += 1
        guard stallAttempts <= 3 else {
            stallAttempts = 0
            await MainActor.run {
                self.giveUpOrRetry(state, "Sensor steht seit \(quietMinutes) min.")
            }
            return
        }
        let stamp = lastPacketAt.map { Self.clock($0) } ?? "--"
        let line = "Sensor: steht seit \(quietMinutes) min, letztes Paket \(stamp). Verbindung neu (\(stallAttempts))"
        do {
            try await openSensor(state, announce: line)
        } catch {
            await mark(state, "Sensor: Verbindung neu (\(stallAttempts)) fehlgeschlagen. \(error.localizedDescription)")
        }
    }

    @MainActor private func openSensor(_ state: WatchState, announce: String? = nil) async throws {
        sensorGeneration += 1
        let generation = sensorGeneration
        replacingSensor = true
        HandyFreiLibreLink.stop()
        await mark(state, announce ?? (sensorRetries == 0 ? "Sensor: suche" : "Sensor: erneut \(sensorRetries)"))
        do {
            try await HandyFreiLibreLink.reconnect(
            bleAddress: address,
            blePIN: pin,
            phase5RawKey: phase5,
            peripheralID: UUID(uuidString: sensorPeripheralID),
            onGlucose: { mgdl, direction in
                DispatchQueue.main.async {
                    self.absorb(state, mgdl, direction: direction)
                }
            },
            onDisconnect: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, state.handyFreiRunning, !self.replacingSensor else { return }
                    // A link we already replaced must not start a second session.
                    guard generation == self.sensorGeneration else { return }
                    Task { await self.restoreSensor(state) }
                }
            },
            onStatus: { text in
                Task { await self.noteSensor(state, text) }
            }
            )
        } catch {
            replacingSensor = false
            throw error
        }
        replacingSensor = false
        sensorRetries = 0
        await mark(state, "Sensor: verbunden, warte auf Werte")
    }

    @MainActor private func restorePump(_ state: WatchState) async {
        guard state.handyFreiRunning else { return }
        pumpRetries += 1
        guard pumpRetries <= 3 else {
            pumpRetries = 0
            await MainActor.run {
                self.giveUpOrRetry(state, "Pumpe weg.")
            }
            return
        }
        do {
            try await openPump(state, attempt: pumpRetries)
        } catch {
            await MainActor.run {
                self.giveUpOrRetry(state, "Pumpe weg. \(error.localizedDescription)")
            }
        }
    }

    @MainActor private func restoreSensor(_ state: WatchState) async {
        guard state.handyFreiRunning, !replacingSensor else { return }
        sensorRetries += 1
        guard sensorRetries <= 3 else {
            sensorRetries = 0
            await MainActor.run {
                self.giveUpOrRetry(state, "Sensor weg.")
            }
            return
        }
        do {
            try await openSensor(state)
        } catch {
            await restoreSensor(state)
        }
    }

    @MainActor private func noteSensor(_ state: WatchState, _ text: String) async {
        if text.hasPrefix("Sensor: Paket") || text.contains("mg/dL") {
            await MainActor.run { self.lastPacketAt = Date() }
        }
        let lowered = text.lowercased()
        if lowered.contains("warm") || lowered.contains("expired") || lowered.contains("abgelaufen") || lowered.contains("endet") {
            await MainActor.run {
                state.handyFreiAlarm = "\(Self.clockMinute()) \(text)"
            }
        }
        await mark(state, text)
    }

    @MainActor private func mark(_ state: WatchState, _ text: String) async {
        await MainActor.run {
            guard state.handyFreiStatus != text else { return }
            state.handyFreiStatus = text
            log.append([
                "date": Date().timeIntervalSince1970,
                "kind": "stage",
                "text": text
            ])
        }
        await WatchLogger.shared.log("Handy-frei \(text)")
    }

    private static func failureText(stage: String, error: Error) -> String {
        let headline: String
        if let link = error as? HandyFreiLinkError {
            if case let .sensorNotSeen(detail) = link {
                return "\(detail). Die Uhr sucht weiter, auch ohne iPhone."
            }
            switch link {
            case .bluetoothOff:
                headline = "Uhr-Bluetooth aus"
            case .bluetoothDenied:
                headline = "Uhr-Bluetooth nicht erlaubt"
            case .bluetoothUnsupported:
                headline = "Uhr-Bluetooth nicht unterstützt"
            case .notFound where stage == "Pumpe":
                headline = "Pumpe: nicht gefunden (Scan 180 s)"
            case .pumpRefused(_) where stage == "Pumpe":
                headline = "Pumpe: Anmeldung abgelehnt"
            case .pumpRefused(_) where stage == "Pumpe: Status":
                headline = "Pumpe: Status lesen Zeitüberschreitung"
            case .badKey where stage == "Sensor":
                headline = "Sensor: Schlüssel unvollständig"
            case .notFound where stage == "Sensor":
                headline = "Sensor: nicht gefunden"
            case .handshake(_) where stage == "Sensor":
                headline = "Sensor: Handshake"
            default:
                headline = stage == "Pumpe: Verlauf" ? "Pumpe: Verlauf lesen" : "\(stage): \(error.localizedDescription)"
            }
        } else if stage == "Pumpe: Verlauf" {
            headline = "Pumpe: Verlauf lesen"
        } else {
            headline = "\(stage): \(error.localizedDescription)"
        }
        return "\(headline). \(error.localizedDescription). Die Uhr sucht weiter."
    }

    /// Below 10 % battery the loop keeps running, but only to lower insulin (zero and low temps).
    /// Stopping the loop there would also stop the zero temp before a low.
    private func absorb(_ state: WatchState, _ mgdl: Int, direction: String) {
        guard state.handyFreiRunning else { return }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        lowBattery = device.batteryLevel >= 0 && device.batteryLevel < 0.1
        if lowBattery {
            HandyFreiAlarm.fire(
                "handyfrei.battery",
                every: 30 * 60,
                title: "Uhr-Akku unter 10 %",
                body: "Handy-frei senkt nur noch Insulin. Uhr laden oder zum iPhone wechseln."
            )
        } else {
            HandyFreiAlarm.reset("handyfrei.battery")
        }
        evaluate(state, mgdl: mgdl, appendReading: true, direction: direction)
    }

    private func secondsUntilLoop() -> Int {
        guard lastSuccess != .distantPast else { return 0 }
        return max(0, Int((5 * 60) - Date().timeIntervalSince(lastSuccess)))
    }

    /// Shown between determinations. This is not a failure.
    /// Which keys from the iPhone copy are missing. Without them neither pump nor sensor can connect.
    private func missingKeys() -> [String] {
        var missing: [String] = []
        if (Data(base64Encoded: pumpSerial) ?? Data()).isEmpty { missing.append("Pumpen-Seriennummer") }
        if (Data(base64Encoded: sessionToken) ?? Data()).isEmpty { missing.append("Pumpen-Token") }
        if address.filter(\.isHexDigit).count < 12 { missing.append("Sensor-Adresse") }
        if pin.count != 4 { missing.append("Sensor-PIN") }
        if phase5.count != 16 { missing.append("Sensor-Schlüssel") }
        return missing
    }

    /// An old reading carries its age, so a value from the last session does not look current.
    private func readingText(_ mgdl: Int) -> String {
        guard let newest = readings.map(\.date).max() else { return "\(mgdl) mg/dL" }
        let age = Date().timeIntervalSince(newest)
        guard age > 6 * 60 else { return "\(mgdl) mg/dL" }
        let minutes = Int(age / 60)
        return minutes < 120 ? "\(mgdl) mg/dL vor \(minutes) min" : "\(mgdl) mg/dL vor \(minutes / 60) h"
    }

    private func showWaiting(_ state: WatchState, mgdl: Int, remain: Int) {
        let line = "\(Self.clockMinute()) \(readingText(mgdl)) · nächster Loop in \(remain)s · \(lastReason)"
        state.handyFreiGlucose = mgdl
        state.handyFreiStatus = line
        state.handyFreiLoopLine = line
    }

    func insulinHistory(_ state: WatchState) -> [HandyFreiLoop.HistoryLine] {
        HandyFreiLoop.insulinLines(files: state.handyFreiFiles, deliveries: deliveries, now: Date())
    }

    func mealHistory(_ state: WatchState) -> [HandyFreiLoop.HistoryLine] {
        HandyFreiLoop.mealLines(files: state.handyFreiFiles, carbs: loopCarbs(), now: Date())
    }

    private func prepareFiles(_ state: WatchState) {
        state.handyFreiFiles = HandyFreiLoop.prepareLoopFiles(
            files: state.handyFreiFiles,
            rheosBasal: state.handyFreiBasal,
            rheosISF: state.handyFreiISF,
            rheosCarbRatio: state.handyFreiCarbRatio,
            glucose: readings,
            deliveries: deliveries,
            watchCarbs: loopCarbs(),
            now: Date()
        )
    }

    private func tickNow(_ state: WatchState) -> HandyFreiLoop.Outcome {
        let live = HandyFreiMedtrumLink.shared.liveBasal()
        return HandyFreiLoop.tick(
            files: state.handyFreiFiles,
            rheosBasal: state.handyFreiBasal,
            rheosISF: state.handyFreiISF,
            rheosCarbRatio: state.handyFreiCarbRatio,
            glucose: readings,
            deliveries: deliveries,
            watchCarbs: loopCarbs(),
            now: Date(),
            directions: directions,
            liveBasalKnown: live.known,
            liveBasalIsTemp: live.isTemp,
            liveBasalRate: live.rate,
            liveBasalStarted: live.started,
            insulinHold: insulinHoldUntil != nil || lowBattery
        )
    }

    private func loopCarbs() -> [HandyFreiLoop.WatchCarb] {
        carbs.map {
            HandyFreiLoop.WatchCarb(
                id: $0.id,
                date: Date(timeIntervalSince1970: $0.date),
                grams: $0.grams,
                fat: $0.fat,
                protein: $0.protein,
                isFPU: $0.isFPU,
                fpuID: $0.fpuID
            )
        }
    }

    /// Keeps a day of glucose, doses, meals and the hand-back log. Older rows are dropped.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
        readings.removeAll { $0.date.timeIntervalSince1970 < cutoff }
        if readings.count > 1500 { readings.removeFirst(readings.count - 1500) }
        deliveries.removeAll { $0.date.timeIntervalSince1970 < cutoff }
        carbs.removeAll { $0.date < cutoff }
        directions = directions.filter { $0.key >= cutoff }
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }

    /// One loop pass. A minute that arrives while a run is in progress, or before five minutes are up, does not start another determination.
    private func evaluate(_ state: WatchState, mgdl: Int, appendReading: Bool, force: Bool = false, direction: String = "") {
        if appendReading {
            let stamp = Date()
            readings.append((stamp, mgdl))
            if !direction.isEmpty { directions[stamp.timeIntervalSince1970] = direction }
            state.trend = direction.isEmpty ? state.trend : direction
            stallAttempts = 0
            prune()
            log.append(["date": Date().timeIntervalSince1970, "kind": "glucose", "mgdl": mgdl])
            HandyFreiDisk.save(session: self, urgent: false)
            HandyFreiAlarm.check(mgdl: mgdl, files: state.handyFreiFiles)
        }
        let revision = mealRevision
        let remain = secondsUntilLoop()
        if determining || dosing || (!force && remain > 0) {
            if appendReading {
                let age = lastSuccess == .distantPast ? 0 : Int(Date().timeIntervalSince(lastSuccess) / 60)
                state.applyHandyFreiDisplay(
                    mgdl: mgdl,
                    iob: lastIOB,
                    cob: lastCOB,
                    loopLine: state.handyFreiLoopLine,
                    loopAgeMinutes: age
                )
            }
            if determining || dosing {
                state.handyFreiStatus = "\(Self.clockMinute()) \(mgdl) mg/dL · Loop läuft · \(lastReason)"
            } else {
                showWaiting(state, mgdl: mgdl, remain: remain)
            }
            return
        }
        determining = true
        prepareFiles(state)
        let outcome = tickNow(state)
        determining = false
        guard revision == mealRevision else { return }
        lastLoopAt = Date()
        let watched = force ? "Loop-Wächter. " : ""
        if outcome.failed {
            lastSuccess = Date()
            lastLoopAt = lastSuccess
            lastReason = outcome.reason
            let line = "\(watched)\(Self.clockMinute()) \(mgdl) mg/dL · \(outcome.reason)"
            state.handyFreiGlucose = mgdl
            state.handyFreiStatus = line
            state.handyFreiLoopLine = line
            log.append(["date": Date().timeIntervalSince1970, "kind": "determination", "text": line])
            HandyFreiDisk.save(session: self, urgent: false)
            return
        }
        lastSuccess = Date()
        lastDose = lastSuccess
        lastReason = outcome.reason
        lastIOB = outcome.iob
        lastCOB = outcome.cob
        HandyFreiAlarm.checkForecast(outcome.forecast20, carbsRequired: outcome.carbsRequired, files: state.handyFreiFiles)
        let preview = "\(watched)\(Self.clockMinute()) \(mgdl) mg/dL · Temp \(String(format: "%.2f", outcome.rate)) U/h \(outcome.minutes) min · SMB \(String(format: "%.2f", outcome.smb)) U · \(outcome.reason)"
        state.handyFreiGlucose = mgdl
        state.handyFreiStatus = preview
        state.handyFreiLoopLine = preview
        state.iob = String(format: "%.1f", outcome.iob)
        state.cob = String(format: "%.0f", outcome.cob)
        if appendReading {
            state.applyHandyFreiDisplay(
                mgdl: mgdl,
                iob: outcome.iob,
                cob: outcome.cob,
                loopLine: preview,
                loopAgeMinutes: 0
            )
        }
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "determination",
            "text": preview,
            "iob": outcome.iob,
            "cob": outcome.cob,
            "mgdl": mgdl
        ])
        HandyFreiDisk.save(session: self, urgent: false)
        // "No temp required" keeps the running temp and needs no pump traffic.
        let setsTemp = outcome.setTemp && outcome.minutes > 0
        let changesTemp = setsTemp || outcome.cancelTemp
        guard changesTemp || (outcome.deliver && outcome.smb > 0) else { return }
        guard !dosing else { return }
        dosing = true
        doseStartedAt = Date()
        lastDose = Date()
        let epoch = doseEpoch
        let rate = Self.medtrumStep(min(outcome.rate, outcome.maxBasal))
        let units = Self.medtrumStep(min(outcome.smb, outcome.maxBolus))
        let uncertain = bolusUncertain
        Task { @MainActor in
            var finished = preview
            defer {
                let line = finished
                Task { @MainActor in
                    self.dosing = false
                    self.doseStartedAt = nil
                    state.handyFreiStatus = line
                    state.handyFreiLoopLine = line
                }
            }
            guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
            if changesTemp {
                // A zero temp (rate 0, minutes > 0) is sent as a temp. Only a cancel uses minutes 0.
                let tempRate = setsTemp ? rate : 0
                let tempMinutes = setsTemp ? outcome.minutes : 0
                let sent = await self.deliverTemp(state, rate: tempRate, minutes: tempMinutes)
                if sent {
                    await MainActor.run {
                        // A cancel is stored as a 0-minute temp so IOB and TDD end the previous temp here.
                        self.deliveries.append(HandyFreiLoop.Delivery(
                            kind: "temp",
                            units: tempRate,
                            minutes: tempMinutes,
                            date: Date(),
                            label: setsTemp ? "" : "Temp-Abbruch"
                        ))
                        self.log.append(["date": Date().timeIntervalSince1970, "kind": "temp", "units": tempRate, "minutes": tempMinutes])
                        HandyFreiDisk.save(session: self)
                    }
                    finished = setsTemp
                        ? "Pumpe \(Self.clockMinute()): Temp \(String(format: "%.2f", tempRate)) U/h \(tempMinutes) min ok"
                        : "Pumpe \(Self.clockMinute()): Temp abgebrochen ok"
                } else {
                    finished = await MainActor.run { state.handyFreiLoopLine }
                }
            }
            let underStep = outcome.smb > 0 && units <= 0
            let overCap = units > 0 && outcome.iob + units > outcome.maxIOB
            if underStep || overCap {
                finished += underStep ? " · SMB unter 0,05 U nicht gesendet" : " · SMB über Max IOB nicht gesendet"
                return
            }
            guard units > 0 else {
                await self.refreshTotals(state, mgdl: mgdl, line: finished)
                return
            }
            if uncertain {
                let cleared = await self.confirmBolusState(state)
                finished += cleared
                    ? " · SMB wartet. Verlauf gelesen, der unsichere Bolus zählt weiter."
                    : " · SMB nicht gesendet, vorheriger Bolus unsicher"
                return
            }
            let bolusSent = await self.deliverBolus(state, units: units)
            if bolusSent {
                await MainActor.run {
                    self.bolusUncertain = false
                    self.deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: units, minutes: 0, date: Date(), label: "SMB"))
                    self.log.append(["date": Date().timeIntervalSince1970, "kind": "bolus", "units": units, "minutes": 0])
                    HandyFreiDisk.save(session: self)
                }
                finished += " · SMB \(String(format: "%.2f", units)) U ok"
                await self.refreshTotals(state, mgdl: mgdl, line: finished, added: units)
            } else {
                await MainActor.run {
                    self.bolusUncertain = true
                    self.deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: units, minutes: 0, date: Date(), label: "SMB"))
                    self.log.append(["date": Date().timeIntervalSince1970, "kind": "bolus", "units": units, "minutes": 0, "text": "SMB unsicher"])
                    HandyFreiDisk.save(session: self)
                }
                finished += " · SMB unsicher, kein zweiter Bolus"
            }
        }
    }

    /// Reads the pump before another SMB when the last bolus reply was missing.
    @MainActor private func confirmBolusState(_ state: WatchState) async -> Bool {
        await MainActor.run {
            state.handyFreiStatus = "\(Self.clockMinute()) Pumpe: Verlauf, bevor ein neues SMB geht."
        }
        do {
            try await HandyFreiMedtrumLink.shared.send(.readStatus)
            try await HandyFreiMedtrumLink.shared.send(.readHistory)
            await MainActor.run { self.bolusUncertain = false }
            return true
        } catch {
            await MainActor.run { self.bolusUncertain = true }
            return false
        }
    }

    /// Shows the result of this pass. The next loop recomputes IOB; a second determine-basal run
    /// only to refresh the display cost as much as the loop itself.
    @MainActor private func refreshTotals(_ state: WatchState, mgdl _: Int, line: String, added: Double = 0) async {
        lastIOB += max(0, added)
        state.iob = String(format: "%.1f", lastIOB)
        state.cob = String(format: "%.0f", lastCOB)
        state.handyFreiStatus = line
        state.handyFreiLoopLine = line
    }

    /// Manual bolus from the + button. Uses the saved pump session. Does not pair again.
    @MainActor func manualBolus(_ state: WatchState, units: Double) async {
        let cap = Double(truncating: state.maxBolus as NSNumber)
        let newest = await MainActor.run { state.handyFreiGlucoseDate ?? Date.distantPast }
        if Date().timeIntervalSince(newest) > 12 * 60 {
            await MainActor.run {
                state.handleAcknowledgment(success: false, message: "Glukose älter als 12 Minuten. Kein Bolus.")
            }
            return
        }
        guard units > 0, units <= cap + 0.001 else {
            await MainActor.run {
                state.handleAcknowledgment(success: false, message: "Über Max Bolus \(String(format: "%.2f", cap)) U.")
            }
            return
        }
        let busy = await MainActor.run { dosing }
        guard !busy else {
            await MainActor.run {
                state.handleAcknowledgment(success: false, message: "Loop spricht gerade mit der Pumpe. Kurz warten.")
            }
            return
        }
        let amount = Self.medtrumStep(units)
        guard amount > 0 else {
            await MainActor.run {
                state.handleAcknowledgment(success: false, message: "Unter 0,05 U. Kein Bolus.")
            }
            return
        }
        await MainActor.run { self.dosing = true }
        let sent = await deliverBolus(state, units: amount)
        await MainActor.run {
            self.dosing = false
            if sent {
                self.deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: amount, minutes: 0, date: Date(), label: "Bolus"))
                self.log.append(["date": Date().timeIntervalSince1970, "kind": "bolus", "units": amount, "minutes": 0])
                HandyFreiDisk.save(session: self)
                state.handyFreiLoopLine = "\(Self.clock()) Bolus \(String(format: "%.2f", amount)) U · Pumpe ok"
                state.handleAcknowledgment(success: true, message: "Bolus \(String(format: "%.2f", amount)) U")
            } else {
                self.bolusUncertain = true
                self.deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: amount, minutes: 0, date: Date(), label: "Bolus"))
                self.log.append([
                    "date": Date().timeIntervalSince1970,
                    "kind": "bolus",
                    "units": amount,
                    "minutes": 0,
                    "text": "Bolus unsicher"
                ])
                HandyFreiDisk.save(session: self)
                state.handleAcknowledgment(success: false, message: "Bolus nicht bestätigt. Er zählt vorsorglich, bis der Verlauf ihn zeigt.")
            }
        }
    }

    /// One retry after a fresh synchronize. A second failure is logged and the loop stays up.
    @MainActor private func deliverTemp(_ state: WatchState, rate: Double, minutes: Int) async -> Bool {
        let label = rate <= 0 ? "cancelTempBasal" : "setTempBasal \(rate)"
        for attempt in 1 ... 2 {
            await MainActor.run { state.handyFreiStatus = "Pumpe: \(label)" }
            do {
                try await HandyFreiMedtrumLink.shared.enactTemp(rate: rate, minutes: minutes)
                return true
            } catch {
                await noteUncertain(error)
                guard attempt == 1, state.handyFreiRunning else {
                    await self.showPumpFailure(state, command: label, error: error)
                    break
                }
                await mark(state, "Pumpe: Sync, dann erneut")
                try? await HandyFreiMedtrumLink.shared.send(.readHistory)
            }
        }
        return false
    }

    @MainActor private func deliverBolus(_ state: WatchState, units: Double) async -> Bool {
        for attempt in 1 ... 2 {
            await MainActor.run { state.handyFreiStatus = "Pumpe: bolus \(units)" }
            do {
                try await HandyFreiMedtrumLink.shared.send(.bolus(units: units))
                return true
            } catch {
                await noteUncertain(error)
                guard attempt == 1, state.handyFreiRunning else {
                    await self.showPumpFailure(state, command: "bolus", error: error)
                    break
                }
                await mark(state, "Pumpe: Sync, dann Bolus erneut")
                try? await HandyFreiMedtrumLink.shared.send(.readHistory)
            }
        }
        return false
    }

    /// Shown on the watch. A missing session is not queued to the iPhone.
    @MainActor private func showPumpFailure(_ state: WatchState, command: String, error: Error) async {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let text = detail == "nicht gefunden"
            ? "\(Self.clock()) \(command): Pumpe nicht verbunden"
            : "\(Self.clock()) \(command) fehlgeschlagen. \(detail)"
        await MainActor.run { state.handyFreiLoopLine = text }
        await mark(state, text)
    }

    private static func clock(_ date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private static func clockMinute(_ date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Rounds down to the patch's 0.05 U step, so a temp or SMB is never above what the loop asked for.
    /// The small epsilon keeps 0.15 at 0.15 when the division lands a hair below 3.
    private static func medtrumStep(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        return ((value / 0.05) + 1e-6).rounded(.down) * 0.05
    }

    /// The command may already be on the pump. The iPhone reads the pump history after it reconnects.
    @MainActor private func noteUncertain(_ error: Error) async {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        await MainActor.run {
            log.append([
                "date": Date().timeIntervalSince1970,
                "kind": "uncertain",
                "text": "Pumpenbefehl unsicher. \(detail). iPhone soll den Pumpenverlauf lesen."
            ])
        }
    }

    func finish(_ state: WatchState) {
        bind(state)
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "stop",
            "text": "Temporäres Basal abbrechen, falls eines gesetzt wurde. Verbindung zu."
        ])
        doseEpoch += 1
        active = false
        HandyFreiDisk.save(session: self)
        state.handyFreiRunning = false
        state.handyFreiTraining = ""
        state.handyFreiYielded = false
        state.handyFreiStatus = "Handy-frei wird beendet. Pumpe und Sensor werden freigegeben…"
        state.reportHandyFreiHeartbeat()
        Task { @MainActor in
            await self.releaseRadios()
            state.handyFreiStatus = "Handy-frei beendet. Pumpe und Sensor sind frei für das iPhone. „Handy-frei aktivieren“ startet wieder, auch ohne iPhone."
        }
    }

    /// Set when the temp cancel at the end of a stretch has answered.
    private var releaseAnswered = false

    /// Hands pump and sensor back in an order the iPhone can rely on. The final log is what lets
    /// the iPhone dose again, so it goes only after the watch has let go of the patch: sensor
    /// closed, temp cancelled (at most 15 s), pump connection closed, a short pause for the patch
    /// to advertise again, then the log. The workout ends last, so watchOS keeps the app running
    /// until all of that is done. Ending the workout first let the app sleep with the patch still
    /// connected, and the iPhone then timed out on it.
    @MainActor private func releaseRadios() async {
        HandyFreiLibreLink.stop()
        releaseAnswered = false
        Task { @MainActor in
            try? await HandyFreiMedtrumLink.shared.send(.cancelTempBasal)
            self.releaseAnswered = true
        }
        let deadline = Date().addingTimeInterval(15)
        while !releaseAnswered, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if !releaseAnswered { HandyFreiMedtrumLink.shared.cancelPendingWrite() }
        HandyFreiMedtrumLink.shared.stop()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        flushOutbox(final: true)
        HandyFreiWorkout.shared.stop()
    }

    private func phoneReachable(_ state: WatchState) -> Bool {
        guard let session = state.session else { return false }
        return session.activationState == .activated && session.isReachable
    }

    /// Ends the session only when the iPhone can take the radio back. Otherwise keeps retrying.
    private func giveUpOrRetry(_ state: WatchState, _ text: String) {
        guard state.handyFreiRunning else { return }
        if phoneReachable(state) {
            fail(state, text)
            return
        }
        state.handyFreiAlarm = "\(Self.clockMinute()) \(text)"
        state.handyFreiStatus = "\(Self.clockMinute()) \(text) Nächster Versuch in 90 s. Die Uhr macht weiter, auch ohne iPhone."
        state.handyFreiLoopLine = ""
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "alarm",
            "text": state.handyFreiStatus
        ])
        guard backoffTask == nil else { return }
        let epoch = doseEpoch
        backoffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.doseEpoch == epoch { self.backoffTask = nil }
            }
            while state.handyFreiRunning, epoch == self.doseEpoch {
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
                if self.phoneReachable(state) {
                    await MainActor.run {
                        self.fail(state, "iPhone ist wieder da. Steuerung zurück.")
                    }
                    return
                }
                await self.mark(state, "Verbindung neu. Pumpenverlauf zuerst, dann der Sensor.")
                self.sensorRetries = 0
                self.pumpRetries = 0
                self.stallAttempts = 0
                await self.keepAwake(state, reason: "Verbindung neu")
                do {
                    try await self.openPump(state, attempt: 1)
                    guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
                    try await self.openSensor(state)
                    await self.mark(state, "Sensor und Pumpe: Versuch geschafft.")
                    await MainActor.run { self.startGlucoseWatch(state, epoch: epoch) }
                    return
                } catch {
                    await self.mark(state, "Noch nicht verbunden. Nächster Versuch in 90 s. \(error.localizedDescription)")
                }
            }
        }
    }

    private weak var boundState: WatchState?

    /// The view that owns the buttons. A background wake uses the same object.
    func bind(_ state: WatchState) {
        boundState = state
    }

    /// After a crash, kill, or reboot, the next launch reads the saved session and starts the workout and the scan again.
    func resumeIfNeeded(_ state: WatchState) {
        bind(state)
        guard !state.handyFreiRunning, HandyFreiDisk.wasActive() else { return }
        state.handyFreiStatus = "Handy-frei wird aus der letzten Kopie fortgesetzt."
        restartFromCache(state)
    }

    func wakeFromBackground() {
        guard HandyFreiDisk.wasActive() || boundState?.handyFreiRunning == true else { return }
        scheduleRefresh()
        guard let state = boundState else { return }
        if state.handyFreiRunning {
            if !HandyFreiWorkout.shared.isRunning {
                Task { await self.keepAwake(state, reason: "Hintergrund") }
            }
        } else {
            resumeIfNeeded(state)
        }
    }

    /// watchOS relaunched the app in the background because its workout was still active
    /// (crash, memory kill). A stretch that was running continues; the workout is taken over in
    /// `HandyFreiWorkout.prepare`. A workout without a running stretch is ended.
    @MainActor func recoverWorkout() async {
        let state = boundState ?? WatchState.shared
        bind(state)
        if HandyFreiDisk.wasActive() {
            log.append(["date": Date().timeIntervalSince1970, "kind": "stage", "text": "Workout nach Neustart der App übernommen."])
            resumeIfNeeded(state)
        } else if await HandyFreiWorkout.shared.recover() {
            HandyFreiWorkout.shared.stop()
        }
    }

    private func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(15 * 60),
            userInfo: nil
        ) { _ in }
    }

    func restartFromCache(_ state: WatchState) {
        backoffTask?.cancel()
        backoffTask = nil
        doseEpoch += 1
        state.handyFreiRunning = false
        state.handyFreiAlarm = ""
        HandyFreiLibreLink.stop()
        HandyFreiMedtrumLink.shared.stop()
        start(state)
    }

    private func fail(_ state: WatchState, _ text: String) {
        bind(state)
        guard state.handyFreiRunning else { return }
        doseEpoch += 1
        state.handyFreiRunning = false
        state.handyFreiAlarm = text
        state.handyFreiTraining = ""
        state.handyFreiYielded = false
        WKInterfaceDevice.current().play(.notification)
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "alarm",
            "text": text
        ])
        active = false
        HandyFreiDisk.save(session: self)
        state.reportHandyFreiHeartbeat()
        Task { @MainActor in
            await self.releaseRadios()
        }
    }

    /// Queued delivery of every dose, glucose and meal the phone does not have yet.
    /// Every flush carries all rows the phone has not acknowledged. While the phone is away the
    /// rows go into the WatchConnectivity queue, so an older queued copy is cancelled first and the
    /// flush runs only every 10 minutes. Otherwise the queue grows by a full copy every 45 seconds.
    func flushOutbox(final: Bool) {
        guard WCSession.isSupported() else { return }
        let session = boundState?.session ?? WCSession.default
        guard session.activationState == .activated else { return }
        let interval: TimeInterval = session.isReachable ? 45 : 10 * 60
        if !final, Date().timeIntervalSince(lastOutboxFlush) < interval { return }
        HandyFreiDisk.preload(self)
        lastOutboxFlush = Date()
        var isFinal = final
        for transfer in session.outstandingUserInfoTransfers where transfer.userInfo["handyFreiLog"] != nil {
            if (transfer.userInfo["handyFreiLogFinal"] as? Bool) == true { isFinal = true }
            transfer.cancel()
        }
        let rows = outboxRows()
        if rows.isEmpty {
            guard isFinal else { return }
            sendOutboxChunk([], final: true, session: session)
            return
        }
        let size = 80
        var index = 0
        while index < rows.count {
            let end = min(index + size, rows.count)
            sendOutboxChunk(Array(rows[index ..< end]), final: isFinal && end == rows.count, session: session)
            index = end
        }
    }

    func noteAck(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        ackedLogIDs.formUnion(ids)
        var stored = Array(ackedLogIDs)
        if stored.count > 3000 { stored.removeFirst(stored.count - 2000) }
        ackedLogIDs = Set(stored)
        UserDefaults.standard.set(stored, forKey: "handyfrei.ackedLogIDs")
    }

    private func outboxRows() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for dose in deliveries {
            let id = "d-\(Int(dose.date.timeIntervalSince1970))-\(dose.kind)-\(Int((dose.units * 100).rounded()))"
            if ackedLogIDs.contains(id) { continue }
            rows.append([
                "id": id,
                "date": dose.date.timeIntervalSince1970,
                "kind": dose.kind,
                "units": dose.units,
                "minutes": dose.minutes,
                "label": dose.label,
                "smb": dose.label == "SMB"
            ])
        }
        for reading in readings {
            let id = "g-\(Int(reading.date.timeIntervalSince1970))"
            if ackedLogIDs.contains(id) { continue }
            var row: [String: Any] = [
                "id": id,
                "date": reading.date.timeIntervalSince1970,
                "kind": "glucose",
                "mgdl": reading.mgdl
            ]
            if let direction = directions[reading.date.timeIntervalSince1970] {
                row["direction"] = direction
            }
            rows.append(row)
        }
        for carb in carbs {
            if ackedLogIDs.contains(carb.id) { continue }
            rows.append([
                "id": carb.id,
                "date": carb.date,
                "kind": carb.isFPU ? "fpu" : "carb",
                "grams": carb.grams,
                "units": carb.grams,
                "fat": carb.fat,
                "protein": carb.protein,
                "name": carb.name,
                "fpuID": carb.fpuID ?? ""
            ])
        }
        return rows
    }

    private func sendOutboxChunk(_ rows: [[String: Any]], final: Bool, session: WCSession) {
        var message: [String: Any] = ["handyFreiLog": rows]
        if final { message["handyFreiLogFinal"] = true }
        // One path per chunk. A reachable phone gets it now; a failed send falls back to the queue.
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in
                session.transferUserInfo(message)
            }
        } else {
            session.transferUserInfo(message)
        }
    }

    enum HandyFreiDisk {
        struct Carb: Codable {
            var id: String
            var date: TimeInterval
            var grams: Double
            var fat: Double
            var protein: Double
            var name: String
            var isFPU: Bool
            var fpuID: String?

            init(id: String, date: TimeInterval, grams: Double, fat: Double, protein: Double, name: String, isFPU: Bool = false, fpuID: String? = nil) {
                self.id = id
                self.date = date
                self.grams = grams
                self.fat = fat
                self.protein = protein
                self.name = name
                self.isFPU = isFPU
                self.fpuID = fpuID
            }

            private enum CodingKeys: String, CodingKey {
                case id, date, grams, fat, protein, name, isFPU, fpuID
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                date = try container.decode(TimeInterval.self, forKey: .date)
                grams = try container.decode(Double.self, forKey: .grams)
                fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0
                protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
                name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
                isFPU = try container.decodeIfPresent(Bool.self, forKey: .isFPU) ?? false
                fpuID = try container.decodeIfPresent(String.self, forKey: .fpuID)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(id, forKey: .id)
                try container.encode(date, forKey: .date)
                try container.encode(grams, forKey: .grams)
                try container.encode(fat, forKey: .fat)
                try container.encode(protein, forKey: .protein)
                try container.encode(name, forKey: .name)
                try container.encode(isFPU, forKey: .isFPU)
                try container.encodeIfPresent(fpuID, forKey: .fpuID)
            }
        }

        struct StoredDelivery: Codable {
            var kind: String
            var units: Double
            var minutes: Int
            var date: TimeInterval
            var label: String

            init(kind: String, units: Double, minutes: Int, date: TimeInterval, label: String = "") {
                self.kind = kind
                self.units = units
                self.minutes = minutes
                self.date = date
                self.label = label
            }

            private enum CodingKeys: String, CodingKey {
                case kind, units, minutes, date, label
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kind = try container.decode(String.self, forKey: .kind)
                units = try container.decode(Double.self, forKey: .units)
                minutes = try container.decode(Int.self, forKey: .minutes)
                date = try container.decode(TimeInterval.self, forKey: .date)
                label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(kind, forKey: .kind)
                try container.encode(units, forKey: .units)
                try container.encode(minutes, forKey: .minutes)
                try container.encode(date, forKey: .date)
                try container.encode(label, forKey: .label)
            }
        }

        struct Reading: Codable {
            var date: TimeInterval
            var mgdl: Int
            var direction: String?

            init(date: TimeInterval, mgdl: Int, direction: String? = nil) {
                self.date = date
                self.mgdl = mgdl
                self.direction = direction
            }

            private enum CodingKeys: String, CodingKey { case date, mgdl, direction }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                date = try container.decode(TimeInterval.self, forKey: .date)
                mgdl = try container.decode(Int.self, forKey: .mgdl)
                direction = try container.decodeIfPresent(String.self, forKey: .direction)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(date, forKey: .date)
                try container.encode(mgdl, forKey: .mgdl)
                try container.encodeIfPresent(direction, forKey: .direction)
            }
        }

        struct File: Codable {
            var files: [String: String] = [:]
            var basal: [Double] = []
            var isf: [Double] = []
            var carbRatio: [Double] = []
            var presets: [MealPresetWatch] = []
            var deliveries: [StoredDelivery] = []
            var carbs: [Carb] = []
            var readings: [Reading] = []
            var lastSuccess: TimeInterval = 0
            var lastReason: String = ""
            var lastIOB: Double = 0
            var lastCOB: Double = 0
            var bleAddress = ""
            var sensorPeripheralID = ""
            var blePIN = ""
            var phase5 = ""
            var pumpSerial = ""
            var sessionToken = ""
            var backupToken = ""
            var snapshotAt: TimeInterval = 0
            var logJSON: Data = Data()
            var active = false

            private enum CodingKeys: String, CodingKey {
                case files
                case basal
                case isf
                case carbRatio
                case presets
                case deliveries
                case carbs
                case readings
                case lastSuccess
                case lastReason
                case lastIOB
                case lastCOB
                case bleAddress
                case sensorPeripheralID
                case blePIN
                case phase5
                case pumpSerial
                case sessionToken
                case backupToken
                case snapshotAt
                case logJSON
                case active
            }

            init() {}

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                files = try container.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
                basal = try container.decodeIfPresent([Double].self, forKey: .basal) ?? []
                isf = try container.decodeIfPresent([Double].self, forKey: .isf) ?? []
                carbRatio = try container.decodeIfPresent([Double].self, forKey: .carbRatio) ?? []
                presets = (try? container.decode([MealPresetWatch].self, forKey: .presets)) ?? []
                deliveries = try container.decodeIfPresent([StoredDelivery].self, forKey: .deliveries) ?? []
                carbs = try container.decodeIfPresent([Carb].self, forKey: .carbs) ?? []
                readings = try container.decodeIfPresent([Reading].self, forKey: .readings) ?? []
                lastSuccess = try container.decodeIfPresent(TimeInterval.self, forKey: .lastSuccess) ?? 0
                lastReason = try container.decodeIfPresent(String.self, forKey: .lastReason) ?? ""
                lastIOB = try container.decodeIfPresent(Double.self, forKey: .lastIOB) ?? 0
                lastCOB = try container.decodeIfPresent(Double.self, forKey: .lastCOB) ?? 0
                bleAddress = try container.decodeIfPresent(String.self, forKey: .bleAddress) ?? ""
                sensorPeripheralID = try container.decodeIfPresent(String.self, forKey: .sensorPeripheralID) ?? ""
                blePIN = try container.decodeIfPresent(String.self, forKey: .blePIN) ?? ""
                phase5 = try container.decodeIfPresent(String.self, forKey: .phase5) ?? ""
                pumpSerial = try container.decodeIfPresent(String.self, forKey: .pumpSerial) ?? ""
                sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
                backupToken = try container.decodeIfPresent(String.self, forKey: .backupToken) ?? ""
                snapshotAt = try container.decodeIfPresent(TimeInterval.self, forKey: .snapshotAt) ?? 0
                logJSON = try container.decodeIfPresent(Data.self, forKey: .logJSON) ?? Data()
                active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(files, forKey: .files)
                try container.encode(basal, forKey: .basal)
                try container.encode(isf, forKey: .isf)
                try container.encode(carbRatio, forKey: .carbRatio)
                try container.encode(presets, forKey: .presets)
                try container.encode(deliveries, forKey: .deliveries)
                try container.encode(carbs, forKey: .carbs)
                try container.encode(readings, forKey: .readings)
                try container.encode(lastSuccess, forKey: .lastSuccess)
                try container.encode(lastReason, forKey: .lastReason)
                try container.encode(lastIOB, forKey: .lastIOB)
                try container.encode(lastCOB, forKey: .lastCOB)
                try container.encode(bleAddress, forKey: .bleAddress)
                try container.encode(sensorPeripheralID, forKey: .sensorPeripheralID)
                try container.encode(blePIN, forKey: .blePIN)
                try container.encode(phase5, forKey: .phase5)
                try container.encode(pumpSerial, forKey: .pumpSerial)
                try container.encode(sessionToken, forKey: .sessionToken)
                try container.encode(backupToken, forKey: .backupToken)
                try container.encode(snapshotAt, forKey: .snapshotAt)
                try container.encode(logJSON, forKey: .logJSON)
                try container.encode(active, forKey: .active)
            }
        }

        /// The decoded file stays in memory, so a save does not read and decode it first.
        private static var cache: File?
        private static var lastWrite = Date.distantPast

        /// Doses, meals, adjustments and stops are written at once (`urgent`). Glucose and
        /// determination rows are written at most every 5 minutes; the next write carries them.
        /// The loop files are written too, so an override or autosens from the watch survives a relaunch.
        static func save(session: HandyFreiSession, urgent: Bool = true) {
            defer { session.flushOutbox(final: false) }
            guard urgent || Date().timeIntervalSince(lastWrite) >= 5 * 60 else { return }
            var file = load() ?? File()
            if let state = session.boundState, !state.handyFreiFiles.isEmpty {
                file.files = state.handyFreiFiles
            }
            file.deliveries = session.deliveries.map {
                StoredDelivery(kind: $0.kind, units: $0.units, minutes: $0.minutes, date: $0.date.timeIntervalSince1970, label: $0.label)
            }
            file.carbs = session.carbs
            file.readings = session.readings.map {
                Reading(date: $0.date.timeIntervalSince1970, mgdl: $0.mgdl, direction: session.directions[$0.date.timeIntervalSince1970])
            }
            file.lastSuccess = session.lastSuccess.timeIntervalSince1970
            file.lastReason = session.lastReason
            file.lastIOB = session.lastIOB
            file.lastCOB = session.lastCOB
            file.logJSON = (try? JSONSerialization.data(withJSONObject: session.log)) ?? file.logJSON
            file.active = session.active
            write(file)
        }

        static func preload(_ session: HandyFreiSession) {
            guard session.deliveries.isEmpty, session.readings.isEmpty, session.carbs.isEmpty else { return }
            guard let file = load() else { return }
            session.deliveries = file.deliveries.map {
                HandyFreiLoop.Delivery(
                    kind: $0.kind,
                    units: $0.units,
                    minutes: $0.minutes,
                    date: Date(timeIntervalSince1970: $0.date),
                    label: $0.label
                )
            }
            session.carbs = file.carbs
            session.readings = file.readings.map { (date: Date(timeIntervalSince1970: $0.date), mgdl: $0.mgdl) }
            var arrows: [Double: String] = [:]
            for reading in file.readings {
                if let direction = reading.direction, !direction.isEmpty {
                    arrows[reading.date] = direction
                }
            }
            session.directions = arrows
        }

        static func wasActive() -> Bool {
            load()?.active == true
        }

        static func saveSnapshot(_ state: WatchState) {
            var file = load() ?? File()
            if !state.handyFreiFiles.isEmpty { file.files = state.handyFreiFiles }
            file.basal = state.handyFreiBasal
            file.isf = state.handyFreiISF
            file.carbRatio = state.handyFreiCarbRatio
            file.presets = state.mealPresets
            file.bleAddress = state.handyFreiBleAddress
            file.sensorPeripheralID = state.handyFreiSensorPeripheralID
            file.blePIN = state.handyFreiBlePIN
            file.phase5 = state.handyFreiPhase5
            file.pumpSerial = state.handyFreiPumpSerial
            file.sessionToken = state.handyFreiSessionToken
            file.backupToken = state.handyFreiBackupToken
            if let copied = state.handyFreiSnapshotAt { file.snapshotAt = copied.timeIntervalSince1970 }
            write(file)
        }

        static func restore(into state: WatchState, session: HandyFreiSession) {
            guard let file = load() else { return }
            if !file.files.isEmpty { state.handyFreiFiles = file.files }
            if state.handyFreiBasal.isEmpty { state.handyFreiBasal = file.basal }
            if state.handyFreiISF.isEmpty { state.handyFreiISF = file.isf }
            if state.handyFreiCarbRatio.isEmpty { state.handyFreiCarbRatio = file.carbRatio }
            if state.mealPresets.isEmpty { state.mealPresets = file.presets }
            if state.handyFreiBleAddress.isEmpty { state.handyFreiBleAddress = file.bleAddress }
            if state.handyFreiSensorPeripheralID.isEmpty { state.handyFreiSensorPeripheralID = file.sensorPeripheralID }
            if state.handyFreiBlePIN.isEmpty { state.handyFreiBlePIN = file.blePIN }
            if state.handyFreiPhase5.isEmpty { state.handyFreiPhase5 = file.phase5 }
            if state.handyFreiPumpSerial.isEmpty { state.handyFreiPumpSerial = file.pumpSerial }
            if state.handyFreiSessionToken.isEmpty { state.handyFreiSessionToken = file.sessionToken }
            if state.handyFreiBackupToken.isEmpty { state.handyFreiBackupToken = file.backupToken }
            if state.handyFreiSnapshotAt == nil, file.snapshotAt > 0 {
                state.handyFreiSnapshotAt = Date(timeIntervalSince1970: file.snapshotAt)
            }
            session.deliveries = file.deliveries.map {
                HandyFreiLoop.Delivery(
                    kind: $0.kind,
                    units: $0.units,
                    minutes: $0.minutes,
                    date: Date(timeIntervalSince1970: $0.date),
                    label: $0.label
                )
            }
            session.carbs = file.carbs
            session.readings = file.readings.map { (date: Date(timeIntervalSince1970: $0.date), mgdl: $0.mgdl) }
            var arrows: [Double: String] = [:]
            for reading in file.readings {
                if let direction = reading.direction, !direction.isEmpty {
                    arrows[reading.date] = direction
                }
            }
            session.directions = arrows
            if file.lastSuccess > 1_000_000_000 {
                session.lastSuccess = Date(timeIntervalSince1970: file.lastSuccess)
                session.lastDose = session.lastSuccess
            }
            if !file.lastReason.isEmpty { session.lastReason = file.lastReason }
            session.lastIOB = file.lastIOB
            session.lastCOB = file.lastCOB
            if let restored = try? JSONSerialization.jsonObject(with: file.logJSON) as? [[String: Any]] {
                session.log = restored
            }
        }

        private static func load() -> File? {
            if let cache { return cache }
            guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
            let file = try? JSONDecoder().decode(File.self, from: data)
            cache = file
            return file
        }

        private static func write(_ file: File) {
            cache = file
            lastWrite = Date()
            guard let url = fileURL(), let data = try? JSONEncoder().encode(file) else { return }
            try? data.write(to: url, options: .atomic)
        }

        private static func fileURL() -> URL? {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            let folder = base.appendingPathComponent("HandyFrei", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("snapshot.json")
        }
    }
}

/// One workout session keeps the watch app awake. It does not dose.
/// A second start is not issued while this one is still running.
final class HandyFreiWorkout: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    static let shared = HandyFreiWorkout()
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var onEnd: ((String) -> Void)?
    private var ignoreEnd = false
    private(set) var lastFailure = ""

    var isRunning: Bool {
        switch session?.state {
        case .running, .paused, .prepared:
            return true
        default:
            return false
        }
    }

    /// After a crash or kill, watchOS relaunches the app and keeps its workout running
    /// (`handleActiveWorkoutRecovery`). That session is taken over instead of starting a second one.
    @MainActor func recover() async -> Bool {
        if isRunning { return true }
        let recovered: HKWorkoutSession? = await withCheckedContinuation { continuation in
            store.recoverActiveWorkoutSession { session, _ in
                continuation.resume(returning: session)
            }
        }
        guard let recovered, recovered.state == .running || recovered.state == .paused else { return false }
        ignoreEnd = false
        recovered.delegate = self
        let builder = recovered.associatedWorkoutBuilder()
        builder.delegate = self
        session = recovered
        self.builder = builder
        if recovered.state == .paused { recovered.resume() }
        return true
    }

    @MainActor func prepare(onEnd: @escaping (String) -> Void) async -> Bool {
        self.onEnd = onEnd
        if isRunning { return true }
        let workout = HKObjectType.workoutType()
        do {
            try await store.requestAuthorization(toShare: [workout], read: [workout])
        } catch {
            lastFailure = "HealthKit: \(error.localizedDescription)"
            return false
        }
        guard store.authorizationStatus(for: workout) == .sharingAuthorized else {
            lastFailure = "HealthKit: Workouts nicht erlaubt"
            return false
        }
        if await recover() { return true }
        return await begin(activity: .other, location: .indoor, training: nil)
    }

    /// The training running in place of the keep-alive, or nil.
    private(set) var trainingName: String?

    /// Ends this session when another app (the Workout app) starts a workout. watchOS runs one at a time.
    static let foreignReason = "Training in einer anderen App"

    /// Starts a session. The keep-alive (`training == nil`) collects nothing and is never saved.
    /// A training collects heart rate and energy and is saved to Health when it ends.
    @MainActor private func begin(
        activity: HKWorkoutActivityType,
        location: HKWorkoutSessionLocationType,
        training: String?
    ) async -> Bool {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        configuration.locationType = location
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.delegate = self
            let source = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            if training == nil {
                // The keep-alive only keeps the app running. The loop needs neither heart rate nor
                // energy, and continuous workout heart rate is the largest battery cost of a long day.
                let unused: [HKQuantityTypeIdentifier] = [.heartRate, .activeEnergyBurned, .basalEnergyBurned]
                for identifier in unused {
                    if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                        source.disableCollection(for: type)
                    }
                }
            }
            builder.dataSource = source
            ignoreEnd = false
            session.delegate = self
            self.session = session
            self.builder = builder
            trainingName = training
            let started = Date()
            session.startActivity(with: started)
            do {
                try await builder.beginCollection(at: started)
            } catch {
                lastFailure = "Sammlung: \(error.localizedDescription)"
                ignoreEnd = true
                self.session = nil
                self.builder = nil
                trainingName = nil
                session.end()
                return false
            }
            lastFailure = ""
            return true
        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    /// Replaces the keep-alive with a real training. Started here, the same session keeps the loop
    /// alive and is saved to Health. If the training cannot start, the keep-alive starts again.
    @MainActor func startTraining(_ activity: HKWorkoutActivityType, name: String, outdoor: Bool) async -> Bool {
        await requestTrainingAccess()
        endQuietly(save: trainingName != nil)
        if await begin(activity: activity, location: outdoor ? .outdoor : .indoor, training: name) { return true }
        let failure = lastFailure
        _ = await begin(activity: .other, location: .indoor, training: nil)
        lastFailure = failure
        return false
    }

    /// Ends the training, saves it to Health and goes back to the keep-alive.
    @MainActor func endTraining() async -> Bool {
        guard trainingName != nil else { return isRunning }
        endQuietly(save: true)
        return await begin(activity: .other, location: .indoor, training: nil)
    }

    private func requestTrainingAccess() async {
        var share: Set<HKSampleType> = [HKObjectType.workoutType()]
        var read: Set<HKObjectType> = []
        let types: [HKQuantityTypeIdentifier] = [
            .heartRate, .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning, .distanceCycling
        ]
        for identifier in types {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                share.insert(type)
                read.insert(type)
            }
        }
        try? await store.requestAuthorization(toShare: share, read: read)
    }

    /// Ends the current session without the restart callback. A training is saved, the keep-alive discarded.
    private func endQuietly(save: Bool) {
        ignoreEnd = true
        let collected = builder
        let ending = session
        builder = nil
        session = nil
        trainingName = nil
        ending?.end()
        collected?.endCollection(withEnd: Date()) { _, _ in
            if save {
                collected?.finishWorkout { _, _ in }
            } else {
                collected?.discardWorkout()
            }
        }
    }

    func stop() {
        onEnd = nil
        endQuietly(save: trainingName != nil)
    }

    /// HealthKit calls these on its own queue. Session state is only changed on the main thread.
    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date _: Date
    ) {
        DispatchQueue.main.async {
            switch toState {
            case .paused:
                // Not a real workout: a pause (for example a button press) would only weaken the keep-alive.
                if workoutSession === self.session { workoutSession.resume() }
            case .ended:
                self.reportEnd(workoutSession, "beendet (\(String(describing: fromState)))")
            default:
                break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let foreign = (error as? HKError)?.code == .errorAnotherWorkoutSessionStarted
        DispatchQueue.main.async {
            self.reportEnd(workoutSession, foreign ? Self.foreignReason : error.localizedDescription)
        }
    }

    func workoutBuilderDidCollectEvent(_: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_: HKLiveWorkoutBuilder, didCollectDataOf _: Set<HKSampleType>) {}

    private func reportEnd(_ ended: HKWorkoutSession, _ reason: String) {
        // An old session that we ended ourselves, or that was already replaced, must not trigger a restart.
        guard let current = session, current === ended else { return }
        if ignoreEnd {
            ignoreEnd = false
            return
        }
        let callback = onEnd
        onEnd = nil
        session = nil
        builder = nil
        trainingName = nil
        callback?(reason)
    }
}

/// Local alarms while the watch loops alone. The iPhone's glucose alarms cannot sound while it is away.
/// Thresholds come from the iPhone's glucose alarms in the copy (`glucoseAlerts`); without them
/// 55 / 70 / 250 mg/dL are used. Everything here runs on the main thread.
enum HandyFreiAlarm {
    struct Limits {
        var urgentLow: Double = 55
        var low: Double = 70
        var high: Double = 270
        var forecastLow: Double = 72
        var carbs: Double = 10
        var urgentLowOn = true
        var lowOn = true
        var highOn = true
        var forecastLowOn = true
        var carbsOn = true
    }

    private static var lastFired: [String: Date] = [:]
    private static var asked = false

    static func requestPermission() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func thresholds(_ files: [String: String]) -> Limits {
        var limits = Limits()
        guard let data = files["glucoseAlerts"]?.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return limits }
        for row in rows {
            guard let type = row["type"] as? String,
                  let threshold = (row["threshold"] as? NSNumber)?.doubleValue, threshold > 0
            else { continue }
            let enabled = (row["enabled"] as? Bool) ?? true
            switch type {
            case "urgentLow":
                limits.urgentLow = threshold
                limits.urgentLowOn = enabled
            case "low":
                limits.low = threshold
                limits.lowOn = enabled
            case "high":
                limits.high = threshold
                limits.highOn = enabled
            case "forecastedLow":
                limits.forecastLow = threshold
                limits.forecastLowOn = enabled
            case "carbsRequired":
                limits.carbs = threshold
                limits.carbsOn = enabled
            default:
                break
            }
        }
        return limits
    }

    /// One new reading. Repeats while it stays out of range: urgent low every 5 minutes,
    /// low every 15 minutes, high every hour. The urgent-low floor sounds even if the low alarm is off.
    static func check(mgdl: Int, files: [String: String]) {
        let bounds = thresholds(files)
        let value = Double(mgdl)
        if value <= max(bounds.urgentLow, 54), bounds.urgentLowOn || value < 55 {
            fire("handyfrei.urgentLow", every: 5 * 60, title: "Dringend niedrig", body: "\(mgdl) mg/dL. Jetzt Kohlenhydrate.")
        } else if bounds.lowOn, value <= bounds.low {
            reset("handyfrei.urgentLow")
            fire("handyfrei.low", every: 15 * 60, title: "Niedrig", body: "\(mgdl) mg/dL.")
        } else {
            reset("handyfrei.urgentLow")
            reset("handyfrei.low")
        }
        if bounds.highOn, value >= bounds.high {
            fire("handyfrei.high", every: 60 * 60, title: "Hoch", body: "\(mgdl) mg/dL.")
        } else {
            reset("handyfrei.high")
        }
    }

    /// After each determination: a low within 20 minutes, and carbs the loop asks for.
    static func checkForecast(_ forecast: Double?, carbsRequired: Double, files: [String: String]) {
        let bounds = thresholds(files)
        if bounds.forecastLowOn, let forecast, forecast <= bounds.forecastLow {
            fire("handyfrei.forecastLow", every: 15 * 60, title: "Bald niedrig", body: "In 20 min etwa \(Int(forecast)) mg/dL.")
        } else {
            reset("handyfrei.forecastLow")
        }
        if bounds.carbsOn, carbsRequired >= bounds.carbs {
            fire("handyfrei.carbs", every: 15 * 60, title: "Kohlenhydrate nötig", body: "Der Loop empfiehlt etwa \(Int(carbsRequired.rounded())) g.")
        } else {
            reset("handyfrei.carbs")
        }
    }

    /// Haptic plus a local notification. The haptic also plays while the workout keeps the app in the background.
    static func fire(_ id: String, every interval: TimeInterval, title: String, body: String) {
        let now = Date()
        if let last = lastFired[id], now.timeIntervalSince(last) < interval { return }
        lastFired[id] = now
        WKInterfaceDevice.current().play(id == "handyfrei.urgentLow" ? .failure : .notification)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "handyfrei"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
    }

    /// The condition ended. The next one fires at once.
    static func reset(_ id: String) {
        lastFired[id] = nil
    }

    static func clear(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}

/// Trainings that run in Handy-frei's own workout. Swimming is left out: it needs water lock and lap settings.
struct HandyFreiTraining {
    let name: String
    let activity: HKWorkoutActivityType
    let outdoor: Bool

    static let all: [HandyFreiTraining] = [
        HandyFreiTraining(name: "Laufen", activity: .running, outdoor: true),
        HandyFreiTraining(name: "Gehen", activity: .walking, outdoor: true),
        HandyFreiTraining(name: "Radfahren", activity: .cycling, outdoor: true),
        HandyFreiTraining(name: "Wandern", activity: .hiking, outdoor: true),
        HandyFreiTraining(name: "Indoor-Rad", activity: .cycling, outdoor: false),
        HandyFreiTraining(name: "Krafttraining", activity: .traditionalStrengthTraining, outdoor: false),
        HandyFreiTraining(name: "HIIT", activity: .highIntensityIntervalTraining, outdoor: false),
        HandyFreiTraining(name: "Anderes Training", activity: .other, outdoor: false)
    ]
}
