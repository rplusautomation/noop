// R+ fork: one-way link between this NOOP build and the owner's Supabase project.
// 1. After every strap sync (Repository.days changes) and on foreground, the last few days of daily
//    summaries, sleep sessions and workouts are pushed through the whoop_push RPC (token-checked,
//    upserts). Summaries only; beat-by-beat data stays on the phone.
// 2. On foreground, the latest weigh-in (og_latest_weight, the gym app's bodyweight log) updates the
//    profile weight, so calories and strain use the current weight.
// Days before the cutover were collected on the Mac and backfilled from there; the phone never
// overwrites them.
import Combine
import Foundation
import UIKit
import WhoopStore

@MainActor
final class RPABridge {
    static let shared = RPABridge()

    private static let cutoverDay = "2026-10-23"
    private static let pushDays = 3

    /// Set by the gym tab; the strap buzz goes through it.
    weak var model: AppModel?
    private var restTask: Task<Void, Never>?

    private weak var repo: Repository?
    private weak var profile: ProfileStore?
    private var bag = Set<AnyCancellable>()
    private var lastPushed: Data?
    private var pushing = false

    func start(repo: Repository, profile: ProfileStore) {
        guard self.repo == nil else { return }
        self.repo = repo
        self.profile = profile
        // This fork wants workout suggestions on: switch NOOP's opt-in detector on once; a later toggle in
        // Settings wins.
        if UserDefaults.standard.object(forKey: PuffinExperiment.autoDetectWorkoutsKey) == nil {
            UserDefaults.standard.set(true, forKey: PuffinExperiment.autoDetectWorkoutsKey)
        }
        repo.$days
            .debounce(for: .seconds(8), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.push() } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { await self?.syncWeight(); await self?.push() } }
            .store(in: &bag)
        Task { await syncWeight() }
        // Chinese by default; the owner can still pick another language in Settings. Takes effect next launch.
        if UserDefaults.standard.string(forKey: AppLanguage.storageKey) == nil {
            UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.storageKey)
            AppLanguage.apply(AppLanguage.chinese.rawValue)
        }
    }

    // MARK: rest buzz

    /// The gym tab started a rest: buzz the strap when it ends instead of the web app's lock-screen
    /// push. Same mechanism as NOOP's own lift rest timer (LiftSessionController): a main-actor task
    /// sleeping until the end; iOS keeps NOOP running while the strap streams.
    func rest(seconds: Int) {
        restTask?.cancel()
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        restTask = Task { [weak self] in
            let delay = end.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.model?.buzz(loops: 3)
        }
    }

    func cancelRest() {
        restTask?.cancel()
        restTask = nil
    }

    // MARK: push

    private func push() async {
        guard let repo, !pushing else { return }
        pushing = true
        defer { pushing = false }
        let days = repo.days.filter { $0.day >= Self.cutoverDay }.sorted { $0.day < $1.day }.suffix(Self.pushDays)
        guard let firstDay = days.first?.day else { return }
        let floorTs = Int(Self.dayStart(firstDay)?.timeIntervalSince1970 ?? 0) - 86_400
        let sleeps = repo.sleeps.filter { $0.startTs >= floorTs }
        let workouts = await repo.workoutRows(days: Self.pushDays + 1).filter { $0.startTs >= floorTs }

        let payload: [String: Any] = [
            "source": "phone",
            "daily": days.map(Self.daily),
            "sleep": sleeps.map(Self.sleep),
            "workouts": workouts.map(Self.workout),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              body != lastPushed else { return }
        let args: [String: Any] = ["p_token": RPASecrets.pushToken, "p": payload]
        if let res = await Self.rpc("whoop_push", args) as? [String: Any], (res["status"] as? Int) == 200 {
            lastPushed = body
        }
    }

    private static func daily(_ d: DailyMetric) -> [String: Any] {
        clean([
            "day": d.day, "total_sleep_min": d.totalSleepMin, "efficiency": d.efficiency, "deep_min": d.deepMin,
            "rem_min": d.remMin, "light_min": d.lightMin, "disturbances": d.disturbances, "resting_hr": d.restingHr,
            "avg_hrv": d.avgHrv, "recovery": d.recovery, "strain": d.strain, "exercise_count": d.exerciseCount,
            "spo2_pct": d.spo2Pct, "skin_temp_dev_c": d.skinTempDevC, "resp_rate_bpm": d.respRateBpm,
            "steps": d.steps, "active_kcal_est": d.activeKcalEst,
        ])
    }

    private static func sleep(_ s: CachedSleepSession) -> [String: Any] {
        let stages = s.stagesJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return clean([
            "start_ts": s.startTs, "end_ts": s.endTs, "efficiency": s.efficiency, "resting_hr": s.restingHr,
            "avg_hrv": s.avgHrv, "stages": stages,
        ])
    }

    private static func workout(_ w: WorkoutRow) -> [String: Any] {
        let zones = w.zonesJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        // A run recorded in NOOP with the phone's GPS keeps its route in RouteStore, not on the row.
        let route = RouteStore.load(startTs: w.startTs, sport: w.sport)
        return clean([
            "start_ts": w.startTs, "end_ts": w.endTs, "sport": w.sport, "origin": w.source, "duration_s": w.durationS,
            "energy_kcal": w.energyKcal, "avg_hr": w.avgHr, "max_hr": w.maxHr, "strain": w.strain,
            "distance_m": w.distanceM ?? route.map { ($0.distanceM * 10).rounded() / 10 }, "zones": zones, "notes": w.notes,
            "route_polyline": route?.polyline,
        ])
    }

    private static func clean(_ d: [String: Any?]) -> [String: Any] { d.compactMapValues { $0 } }

    private static func dayStart(_ day: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    // MARK: weight

    private func syncWeight() async {
        guard let profile, let res = await Self.rpc("og_latest_weight", [:]) as? [String: Any],
              let kg = (res["w"] as? NSNumber)?.doubleValue, kg > 30, kg < 250 else { return }
        if abs(profile.weightKg - kg) >= 0.05 { profile.weightKg = kg }
    }

    // MARK: transport

    private static func rpc(_ fn: String, _ args: [String: Any]) async -> Any? {
        guard let url = URL(string: RPASecrets.supabaseURL + "/rest/v1/rpc/" + fn),
              let body = try? JSONSerialization.data(withJSONObject: args) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(RPASecrets.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer " + RPASecrets.supabaseKey, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
