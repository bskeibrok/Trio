import Combine
import Foundation
import LoopKit
import LoopKitUI
import Swinject

protocol APSManager {
    func fetchAndLoop()
    func autosense()
    func autotune()
    func enactBolus(amount: Double)
    var pumpManager: PumpManagerUI? { get set }
    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> { get }
    func enactTempBasal(rate: Double, duration: TimeInterval)
}

final class BaseAPSManager: APSManager, Injectable {
    private let processQueue = DispatchQueue(label: "BaseAPSManager.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var tempTargetsStorage: TempTargetsStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var announcementsStorage: AnnouncementsStorage!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var nightscout: NightscoutManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    private var openAPS: OpenAPS!

    private var loopCancellable: AnyCancellable?
    private var pumpCancellable: AnyCancellable?
    private var enactCancellable: AnyCancellable?
    private var remoteCancellable: AnyCancellable?

    var pumpManager: PumpManagerUI? {
        get { deviceDataManager.pumpManager }
        set { deviceDataManager.pumpManager = newValue }
    }

    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> {
        deviceDataManager.pumpDisplayState
    }

    var settings: FreeAPSSettings {
        get { settingsManager.settings }
        set { settingsManager.settings = newValue }
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        openAPS = OpenAPS(storage: storage)
        subscribe()
    }

    private func subscribe() {
        pumpCancellable = deviceDataManager.recommendsLoop
            .sink { [weak self] in
                self?.fetchAndLoop()
            }
        pumpManager?.addStatusObserver(self, queue: processQueue)
    }

    func fetchAndLoop() {
        guard pumpManager != nil else {
            loop()
            return
        }

        remoteCancellable = nightscout.fetchAnnouncements()
            .sink { [weak self] in
                if let recent = self?.announcementsStorage.recent(), recent.action != nil {
                    self?.enactAnnouncement(recent)
                } else {
                    self?.loop()
                }
            }
    }

    private func loop() {
        loopCancellable = Publishers.CombineLatest3(
            nightscout.fetchGlucose(),
            nightscout.fetchCarbs(),
            nightscout.fetchTempTargets()
        )
        .flatMap { _ in self.determineBasal() }
        .sink { _ in } receiveValue: { [weak self] ok in
            guard let self = self else { return }
            if ok, let suggested = try? self.storage.retrieve(OpenAPS.Enact.suggested, as: Suggestion.self) {
                DispatchQueue.main.async {
                    self.broadcaster.notify(SuggestionObserver.self, on: .main) {
                        $0.suggestionDidUpdate(suggested)
                    }
                }
            }

            if ok, self.settings.closedLoop {
                self.enactSuggested()
            }
        }
    }

    private func verifyStatus() -> Bool {
        guard let pump = pumpManager else {
            return false
        }
        let status = pump.status.pumpStatus

        guard !status.bolusing, !status.suspended else { return false }

        return true
    }

    private func determineBasal() -> AnyPublisher<Bool, Never> {
        guard let glucose = try? storage.retrieve(OpenAPS.Monitor.glucose, as: [BloodGlucose].self), glucose.count >= 36 else {
            print("Not enough glucose data")
            return Just(false).eraseToAnyPublisher()
        }

        let now = Date()
        let temp = currentTemp(date: now)

        let mainPublisher = openAPS.makeProfiles()
            .flatMap { _ in
                self.openAPS.determineBasal(currentTemp: temp, clock: now)
            }
            .map { true }
            .eraseToAnyPublisher()

        if temp.duration == 0,
           settings.closedLoop,
           settingsManager.preferences.unsuspendIfNoTemp,
           let pump = pumpManager
        {
            return pump.resumeDelivery()
                .flatMap { _ in mainPublisher }
                .replaceError(with: false)
                .eraseToAnyPublisher()
        }

        return mainPublisher
    }

    func enactBolus(amount: Double) {
        guard let pump = pumpManager, verifyStatus() else { return }

        let roundedAmout = pump.roundToSupportedBolusVolume(units: amount)
        pump.enactBolus(units: roundedAmout, automatic: false) { result in
            switch result {
            case .success:
                print("Bolus succeeded")
            case let .failure(error):
                print("Bolus failed with error: \(error.localizedDescription)")
            }
        }
    }

    func enactTempBasal(rate: Double, duration: TimeInterval) {
        guard let pump = pumpManager, verifyStatus() else { return }

        let roundedAmout = pump.roundToSupportedBasalRate(unitsPerHour: rate)
        pump.enactTempBasal(unitsPerHour: roundedAmout, for: duration) { result in
            switch result {
            case .success:
                print("Temp Basal succeeded")
                let temp = TempBasal(duration: Int(duration / 60), rate: Decimal(rate), temp: .absolute, updatedAt: Date())
                try? self.storage.save(temp, as: OpenAPS.Monitor.tempBasal)
            case let .failure(error):
                print("Temp Basal failed with error: \(error.localizedDescription)")
            }
        }
    }

    func autosense() {
        _ = openAPS.autosense()
    }

    func autotune() {
        _ = openAPS.autotune()
    }

    private func enactAnnouncement(_ announcement: Announcement) {
        guard let action = announcement.action else {
            print("Invalid Announcement action")
            return
        }
        switch action {
        case let .bolus(amount):
            guard verifyStatus() else {
                return
            }
            pumpManager?.enactBolus(units: Double(amount), automatic: false) { result in
                switch result {
                case .success:
                    print("Announcement Bolus succeeded")
                    self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                case let .failure(error):
                    print("Announcement Bolus failed with error: \(error.localizedDescription)")
                }
            }
        case let .pump(pumpAction):
            switch pumpAction {
            case .suspend:
                guard verifyStatus() else {
                    return
                }
                pumpManager?.suspendDelivery { error in
                    if let error = error {
                        print("Pump not suspended by Announcement: \(error.localizedDescription)")
                    } else {
                        print("Pump suspended by Announcement")
                        self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                    }
                }
            case .resume:
                pumpManager?.resumeDelivery { error in
                    if let error = error {
                        print("Pump not resumed by Announcement: \(error.localizedDescription)")
                    } else {
                        print("Pump resumed by Announcement")
                        self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                    }
                }
            }
        case let .looping(closedLoop):
            settings.closedLoop = closedLoop
            print("Closed loop \(closedLoop) by Announcement")
            announcementsStorage.storeAnnouncements([announcement], enacted: true)
        case let .tempbasal(rate, duration):
            guard verifyStatus() else {
                return
            }
            pumpManager?.enactTempBasal(unitsPerHour: Double(rate), for: TimeInterval(duration) * 60) { result in
                switch result {
                case .success:
                    print("Announcement TempBasal succeeded")
                    self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                case let .failure(error):
                    print("Announcement TempBasal failed with error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func currentTemp(date: Date) -> TempBasal {
        let defaultTemp = { () -> TempBasal in
            guard let temp = try? storage.retrieve(OpenAPS.Monitor.tempBasal, as: TempBasal.self) else {
                return TempBasal(duration: 0, rate: 0, temp: .absolute, updatedAt: Date())
            }
            let delta = Int((date.timeIntervalSince1970 - temp.updatedAt.timeIntervalSince1970) / 60)
            let duration = max(0, temp.duration - delta)
            return TempBasal(duration: duration, rate: temp.rate, temp: .absolute, updatedAt: date)
        }()

        guard let state = pumpManager?.status.basalDeliveryState else { return defaultTemp }
        switch state {
        case .active:
            return TempBasal(duration: 0, rate: 0, temp: .absolute, updatedAt: date)
        case let .tempBasal(dose):
            let rate = Decimal(dose.unitsPerHour)
            let durationMin = max(0, Int((dose.endDate.timeIntervalSince1970 - date.timeIntervalSince1970) / 60))
            return TempBasal(duration: durationMin, rate: rate, temp: .absolute, updatedAt: date)
        default:
            return defaultTemp
        }
    }

    private func enactSuggested() {
        guard verifyStatus() else {
            return
        }

        guard let pump = pumpManager,
              let suggested = try? storage.retrieve(
                  OpenAPS.Enact.suggested,
                  as: Suggestion.self
              )
        else {
            return
        }

        let basalPublisher: AnyPublisher<Void, Error> = {
            guard let rate = suggested.rate, let duration = suggested.duration else {
                return Just(()).setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            return pump.enactTempBasal(unitsPerHour: Double(rate), for: TimeInterval(duration * 60)).map { _ in
                let temp = TempBasal(duration: duration, rate: rate, temp: .absolute, updatedAt: Date())
                try? self.storage.save(temp, as: OpenAPS.Monitor.tempBasal)
                return ()
            }
            .eraseToAnyPublisher()
        }()

        let bolusPublisher: AnyPublisher<Void, Error> = {
            guard let units = suggested.units else {
                return Just(()).setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            return pump.enactBolus(units: Double(units), automatic: true).map { _ in () }
                .eraseToAnyPublisher()
        }()

        enactCancellable = basalPublisher
            .flatMap { bolusPublisher }
            .sink { completion in
                if case let .failure(error) = completion {
                    print("Loop failed with error: \(error.localizedDescription)")
                }
            } receiveValue: { [weak self] in
                print("Loop succeeded")
                if let rawSuggested = self?.storage.retrieveRaw(OpenAPS.Enact.suggested) {
                    try? self?.storage.save(rawSuggested, as: OpenAPS.Enact.enacted)
                }
            }
    }
}

private extension PumpManager {
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) -> AnyPublisher<DoseEntry, Error> {
        Future { promise in
            self.enactTempBasal(unitsPerHour: unitsPerHour, for: duration) { result in
                switch result {
                case let .success(dose):
                    promise(.success(dose))
                case let .failure(error):
                    promise(.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }

    func enactBolus(units: Double, automatic: Bool) -> AnyPublisher<DoseEntry, Error> {
        Future { promise in
            self.enactBolus(units: units, automatic: automatic) { result in
                switch result {
                case let .success(dose):
                    promise(.success(dose))
                case let .failure(error):
                    promise(.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }

    func resumeDelivery() -> AnyPublisher<Void, Error> {
        Future { promise in
            self.resumeDelivery { error in
                if let error = error {
                    promise(.failure(error))
                } else {
                    promise(.success(()))
                }
            }
        }.eraseToAnyPublisher()
    }
}

extension BaseAPSManager: PumpManagerStatusObserver {
    func pumpManager(_: PumpManager, didUpdate status: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        try? storage.save(status.pumpStatus, as: OpenAPS.Monitor.status)
    }
}

extension PumpManagerStatus {
    var pumpStatus: PumpStatus {
        let bolusing = bolusState != .noBolus
        let suspended = basalDeliveryState?.isSuspended ?? true
        let type = suspended ? StatusType.suspended : (bolusing ? .bolusing : .normal)
        return PumpStatus(status: type, bolusing: bolusing, suspended: suspended)
    }
}