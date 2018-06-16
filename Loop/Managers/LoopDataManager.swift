//
//  LoopDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/12/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import CarbKit
import GlucoseKit
import HealthKit
import InsulinKit
import LoopKit
import UIKit


final class LoopDataManager {
    enum LoopUpdateContext: Int {
        case bolus
        case carbs
        case glucose
        case preferences
        case tempBasal
    }

    static let LoopUpdateContextKey = "com.loudnate.Loop.LoopDataManager.LoopUpdateContext"
    static let LastLoopCompletedKey = "com.loopkit.Loop.LoopDataManager.LastLoopCompleted"

    fileprivate typealias GlucoseChange = (start: GlucoseValue, end: GlucoseValue)

    let carbStore: CarbStore!

    let doseStore: DoseStore

    let glucoseStore: GlucoseStore!

    unowned let delegate: LoopDataManagerDelegate

    private let logger: CategoryLogger
    
    fileprivate var glucoseUpdated: Bool // flag used to decide if integral RC should be updated or not
    fileprivate var initializeIntegralRetrospectiveCorrection: Bool // flag used to decide if integral RC should be initialized upon Loop restart or other reasons
    fileprivate var updatePastEffects: Bool // flag used to decide if past insulin and carb effects should be updated
    
    var overallRetrospectiveCorrection: HKQuantity? // retrospective correction including integral effect
    
    fileprivate var sampleRetrospectiveGlucoseChange: GlucoseChange?
    fileprivate typealias Effect = (
        start: Date,
        end: Date,
        deltaBG: Double,
        discrepancy: Double,
        insulinEffect: Double,
        carbEffect: Double,
        basalEffect: Double
    )
    fileprivate var pastEffects: [Effect]?

    // outputs of the parameter estimator
    struct EstimatedParameters {
        var insulinSensitivityMultipler: Double = 1.0
        var insulinSensitivityConfidence: Double = 0.0
        var carbSensitivityMultiplier: Double = 1.0
        var carbSensitivityConfidence: Double = 0.0
        var carbRatioMultiplier: Double = 1.0
        var carbRatioConfidence: Double = 0.0
        var basalMultiplier: Double = 1.0
        var basalConfidence: Double = 0.0
        var unexpectedPositiveDiscrepancyPercentage: Double = 0.0
        var unexpectedNegativeDiscrepancyPercentage: Double = 0.0
        var estimationBufferPercentage: Double = 0.0
        let estimationHours: Double = 6.0 // short-term estimation runs over estimationHours
        let parameterDeviation: Double = 0.25 // expected max deviation in ISF, CSF, basal rates
        let pointNoiseDeviation: Double = 0.8 // single point confidence = 1 - pointNoiseDeviation
    }

    // parameter estimation setup
    fileprivate var restartRetrospectiveGlucoseChanges: [GlucoseChange]?
    fileprivate let estimationHours: Double = 24.0
    fileprivate var pastGlucoseChanges: [GlucoseChange]?
    fileprivate var pastInsulinEffects: [GlucoseEffect]?
    fileprivate var pastCarbEffects: [GlucoseEffect]?
    var estimatedParameters = EstimatedParameters()
    
    init(
        delegate: LoopDataManagerDelegate,
        lastLoopCompleted: Date?,
        lastTempBasal: DoseEntry?,
        basalRateSchedule: BasalRateSchedule? = UserDefaults.appGroup.basalRateSchedule,
        carbRatioSchedule: CarbRatioSchedule? = UserDefaults.appGroup.carbRatioSchedule,
        insulinModelSettings: InsulinModelSettings? = UserDefaults.appGroup.insulinModelSettings,
        insulinCounteractionEffects: [GlucoseEffectVelocity]? = UserDefaults.appGroup.insulinCounteractionEffects,
        retrospectiveInsulinEffects: [GlucoseEffectVelocity]? = UserDefaults.appGroup.retrospectiveInsulinEffects,
        retrospectiveCarbEffects: [GlucoseEffectVelocity]? =
            UserDefaults.appGroup.retrospectiveCarbEffects,
        retrospectiveBasalEffects: [GlucoseEffectVelocity]? = UserDefaults.appGroup.retrospectiveBasalEffects,
        retrospectiveDiscrepancies: [GlucoseEffectVelocity]? = UserDefaults.appGroup.retrospectiveDiscrepancies,
        glucoseChanges: [GlucoseEffectVelocity]? = UserDefaults.appGroup.glucoseChanges,
        insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.appGroup.insulinSensitivitySchedule,
        settings: LoopSettings = UserDefaults.appGroup.loopSettings ?? LoopSettings()
        ) {
        self.delegate = delegate
        self.logger = DiagnosticLogger.shared!.forCategory("LoopDataManager")
        self.insulinCounteractionEffects = insulinCounteractionEffects ?? []
        self.retrospectiveInsulinEffects = retrospectiveInsulinEffects ?? []
        self.retrospectiveCarbEffects = retrospectiveCarbEffects ?? []
        self.retrospectiveBasalEffects = retrospectiveBasalEffects ?? []
        self.retrospectiveDiscrepancies = retrospectiveDiscrepancies ?? []
        self.glucoseChanges = glucoseChanges ?? []
        self.lastLoopCompleted = lastLoopCompleted
        self.lastTempBasal = lastTempBasal
        self.settings = settings
        
        self.glucoseUpdated = false
        self.initializeIntegralRetrospectiveCorrection = true
        self.overallRetrospectiveCorrection = nil
        self.restartRetrospectiveGlucoseChanges = nil

        self.updatePastEffects = false
        
        self.sampleRetrospectiveGlucoseChange = nil
        self.pastGlucoseChanges = nil
        self.pastInsulinEffects = nil
        self.pastCarbEffects = nil
        self.pastEffects = nil

        let healthStore = HKHealthStore()

        carbStore = CarbStore(
            healthStore: healthStore,
            defaultAbsorptionTimes: (
                fast: TimeInterval(hours: 1.5),
                medium: TimeInterval(hours: 2.5),
                slow: TimeInterval(hours: 13) // TO DO: extend cache in LoopKit instead
            ),
            carbRatioSchedule: carbRatioSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )

        doseStore = DoseStore(
            healthStore: healthStore,
            insulinModel: insulinModelSettings?.model,
            basalProfile: basalRateSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )

        glucoseStore = GlucoseStore(healthStore: healthStore)

        // Observe changes
        carbUpdateObserver = NotificationCenter.default.addObserver(
            forName: .CarbEntriesDidUpdate,
            object: nil,
            queue: nil
        ) { (note) -> Void in
            self.dataAccessQueue.async {
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.notify(forChange: .carbs)
            }
        }
    }

    // MARK: - Preferences

    /// Loop-related settings
    ///
    /// These are not thread-safe.
    var settings: LoopSettings {
        didSet {
            UserDefaults.appGroup.loopSettings = settings
            notify(forChange: .preferences)
            AnalyticsManager.shared.didChangeLoopSettings(from: oldValue, to: settings)
        }
    }

    /// The daily schedule of basal insulin rates
    var basalRateSchedule: BasalRateSchedule? {
        get {
            return doseStore.basalProfile
        }
        set {
            doseStore.basalProfile = newValue
            UserDefaults.appGroup.basalRateSchedule = newValue
            notify(forChange: .preferences)
        }
    }

    /// The daily schedule of carbs-to-insulin ratios
    /// This is measured in grams/Unit
    var carbRatioSchedule: CarbRatioSchedule? {
        get {
            return carbStore.carbRatioSchedule
        }
        set {
            carbStore.carbRatioSchedule = newValue
            UserDefaults.appGroup.carbRatioSchedule = newValue

            // Invalidate cached effects based on this schedule
            carbEffect = nil
            carbsOnBoard = nil
            pastCarbEffects = nil

            notify(forChange: .preferences)
        }
    }

    /// The length of time insulin has an effect on blood glucose
    var insulinModelSettings: InsulinModelSettings? {
        get {
            guard let model = doseStore.insulinModel else {
                return nil
            }

            return InsulinModelSettings(model: model)
        }
        set {
            doseStore.insulinModel = newValue?.model
            UserDefaults.appGroup.insulinModelSettings = newValue

            self.dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.insulinEffect = nil
                self.pastInsulinEffects = nil

                self.notify(forChange: .preferences)
            }

            AnalyticsManager.shared.didChangeInsulinModel()
        }
    }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    fileprivate var insulinCounteractionEffects: [GlucoseEffectVelocity] {
        didSet {
            UserDefaults.appGroup.insulinCounteractionEffects = insulinCounteractionEffects
            carbEffect = nil
            carbsOnBoard = nil
        }
    }

    /// A timeline of 30-min retrospective insulin effects
    fileprivate var retrospectiveInsulinEffects: [GlucoseEffectVelocity] {
        didSet {
            UserDefaults.appGroup.retrospectiveInsulinEffects = retrospectiveInsulinEffects
        }
    }
    
    /// A timeline of 30-min retrospective carb effects
    fileprivate var retrospectiveCarbEffects: [GlucoseEffectVelocity] {
        didSet {
            UserDefaults.appGroup.retrospectiveCarbEffects = retrospectiveCarbEffects
        }
    }
    
    /// A timeline of 30-min retrospective basal effects
    fileprivate var retrospectiveBasalEffects: [GlucoseEffectVelocity] {
        didSet {
            UserDefaults.appGroup.retrospectiveBasalEffects = retrospectiveBasalEffects
        }
    }
    
    /// A timeline of 30-min retrospective discrepancies
    fileprivate var retrospectiveDiscrepancies: [GlucoseEffectVelocity] {
        didSet {
            UserDefaults.appGroup.retrospectiveDiscrepancies = retrospectiveDiscrepancies
        }
    }
    
    /// A timeline of 30-min retrospective changes in BG
    fileprivate var glucoseChanges: [GlucoseEffectVelocity] {
        didSet {
            UserDefaults.appGroup.glucoseChanges = glucoseChanges
        }
    }
    
    /// The daily schedule of insulin sensitivity (also known as ISF)
    /// This is measured in <blood glucose>/Unit
    var insulinSensitivitySchedule: InsulinSensitivitySchedule? {
        get {
            return carbStore.insulinSensitivitySchedule
        }
        set {
            carbStore.insulinSensitivitySchedule = newValue
            doseStore.insulinSensitivitySchedule = newValue

            UserDefaults.appGroup.insulinSensitivitySchedule = newValue

            dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil
                self.pastCarbEffects = nil
                self.pastInsulinEffects = nil

                self.notify(forChange: .preferences)
            }
        }
    }

    /// The amount of time since a given date that data should be considered valid
    var recencyInterval = TimeInterval(minutes: 15)

    /// Sets a new time zone for a the schedule-based settings
    ///
    /// - Parameter timeZone: The time zone
    func setScheduleTimeZone(_ timeZone: TimeZone) {
        self.basalRateSchedule?.timeZone = timeZone
        self.carbRatioSchedule?.timeZone = timeZone
        self.insulinSensitivitySchedule?.timeZone = timeZone
        settings.glucoseTargetRangeSchedule?.timeZone = timeZone
    }

    /// All the HealthKit types to be read by stores
    var readTypes: Set<HKSampleType> {
        return glucoseStore.readTypes.union(
               carbStore.readTypes).union(
               doseStore.readTypes)
    }

    /// All the HealthKit types we to be shared by stores
    var shareTypes: Set<HKSampleType> {
        return glucoseStore.shareTypes.union(
               carbStore.shareTypes).union(
               doseStore.shareTypes)
    }

    /// True if any stores require HealthKit authorization
    var authorizationRequired: Bool {
        return glucoseStore.authorizationRequired ||
               carbStore.authorizationRequired ||
               doseStore.authorizationRequired
    }

    /// True if the user has explicitly denied access to any stores' HealthKit types
    var sharingDenied: Bool {
        return glucoseStore.sharingDenied ||
               carbStore.sharingDenied ||
               doseStore.sharingDenied
    }

    func authorize(_ completion: @escaping () -> Void) {
        carbStore.healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { (success, error) in
            completion()
        }
    }

    // MARK: - Intake

    /// Adds and stores glucose data
    ///
    /// - Parameters:
    ///   - values: The new glucose values to store
    ///   - device: The device that captured the data
    ///   - completion: A closure called once upon completion
    ///   - result: The stored glucose values
    func addGlucose(
        _ values: [(quantity: HKQuantity, date: Date, isDisplayOnly: Bool)],
        from device: HKDevice?,
        completion: ((_ result: Result<[GlucoseValue]>) -> Void)? = nil
    ) {
        glucoseStore.addGlucoseValues(values, device: device) { (success, values, error) in
            if success {
                self.dataAccessQueue.async {
                    self.glucoseMomentumEffect = nil
                    self.lastGlucoseChange = nil
                    self.retrospectiveGlucoseChange = nil
                    self.updatePastEffects = true
                    self.glucoseUpdated = true
                    self.notify(forChange: .glucose)
                }
            }

            if let error = error {
                completion?(.failure(error))
            } else {
                completion?(.success(values ?? []))
            }
        }
    }

    /// Adds and stores carb data, and recommends a bolus if needed
    ///
    /// - Parameters:
    ///   - carbEntry: The new carb value
    ///   - completion: A closure called once upon completion
    ///   - result: The bolus recommendation
    func addCarbEntryAndRecommendBolus(_ carbEntry: CarbEntry, replacing replacingEntry: CarbEntry? = nil, completion: @escaping (_ result: Result<BolusRecommendation?>) -> Void) {
        let addCompletion: (Bool, CarbEntry?, CarbStore.CarbStoreError?) -> Void = { (success, _, error) in
            self.dataAccessQueue.async {
                if success {
                    // Remove the active pre-meal target override
                    self.settings.glucoseTargetRangeSchedule?.clearOverride(matching: .preMeal)

                    self.carbEffect = nil
                    self.carbsOnBoard = nil

                    defer {
                        self.notify(forChange: .carbs)
                    }

                    do {
                        try self.update()

                        completion(.success(self.recommendedBolus?.recommendation))
                    } catch let error {
                        completion(.failure(error))
                    }
                } else if let error = error {
                    completion(.failure(error))
                } else {
                    completion(.success(nil))
                }
            }
        }

        if let replacingEntry = replacingEntry {
            carbStore.replaceCarbEntry(replacingEntry, withEntry: carbEntry, resultHandler: addCompletion)
        } else {
            carbStore.addCarbEntry(carbEntry, resultHandler: addCompletion)
        }
    }

    /// Adds a bolus requested of the pump, but not confirmed.
    ///
    /// - Parameters:
    ///   - units: The bolus amount, in units
    ///   - date: The date the bolus was requested
    func addRequestedBolus(units: Double, at date: Date, completion: (() -> Void)?) {
        dataAccessQueue.async {
            self.lastRequestedBolus = (units: units, date: date)
            self.notify(forChange: .bolus)

            completion?()
        }
    }

    /// Adds a bolus enacted by the pump, but not fully delivered.
    ///
    /// - Parameters:
    ///   - units: The bolus amount, in units
    ///   - date: The date the bolus was enacted
    func addConfirmedBolus(units: Double, at date: Date, completion: (() -> Void)?) {
        self.doseStore.addPendingPumpEvent(.enactedBolus(units: units, at: date)) {
            self.dataAccessQueue.async {
                self.lastRequestedBolus = nil
                self.insulinEffect = nil
                self.pastInsulinEffects = nil
                self.notify(forChange: .bolus)

                completion?()
            }
        }
    }

    /// Adds and stores new pump events
    ///
    /// - Parameters:
    ///   - events: The pump events to add
    ///   - completion: A closure called once upon completion
    ///   - error: An error explaining why the events could not be saved.
    func addPumpEvents(_ events: [NewPumpEvent], completion: @escaping (_ error: DoseStore.DoseStoreError?) -> Void) {
        doseStore.addPumpEvents(events) { (error) in
            self.dataAccessQueue.async {
                if error == nil {
                    self.insulinEffect = nil
                    self.pastInsulinEffects = nil
                    // Expire any bolus values now represented in the insulin data
                    if let bolusDate = self.lastRequestedBolus?.date, bolusDate.timeIntervalSinceNow < TimeInterval(minutes: -5) {
                        self.lastRequestedBolus = nil
                    }
                }

                completion(error)
            }
        }
    }

    /// Adds and stores a pump reservoir volume
    ///
    /// - Parameters:
    ///   - units: The reservoir volume, in units
    ///   - date: The date of the volume reading
    ///   - completion: A closure called once upon completion
    ///   - result: The current state of the reservoir values:
    ///       - newValue: The new stored value
    ///       - lastValue: The previous new stored value
    ///       - areStoredValuesContinuous: Whether the current recent state of the stored reservoir data is considered continuous and reliable for deriving insulin effects after addition of this new value.
    func addReservoirValue(_ units: Double, at date: Date, completion: @escaping (_ result: Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool)>) -> Void) {
        doseStore.addReservoirValue(units, atDate: date) { (newValue, previousValue, areStoredValuesContinuous, error) in
            if let error = error {
                completion(.failure(error))
            } else if let newValue = newValue {
                self.dataAccessQueue.async {
                    self.insulinEffect = nil
                    self.pastInsulinEffects = nil
                    // Expire any bolus values now represented in the insulin data
                    if areStoredValuesContinuous, let bolusDate = self.lastRequestedBolus?.date, bolusDate.timeIntervalSinceNow < TimeInterval(minutes: -5) {
                        self.lastRequestedBolus = nil
                    }

                    completion(.success((
                        newValue: newValue,
                        lastValue: previousValue,
                        areStoredValuesContinuous: areStoredValuesContinuous
                    )))
                }
            } else {
                assertionFailure()
            }
        }
    }

    // Actions

    func enactRecommendedTempBasal(_ completion: @escaping (_ error: Error?) -> Void) {
        dataAccessQueue.async {
            self.setRecommendedTempBasal(completion)
        }
    }

    /// Runs the "loop"
    ///
    /// Executes an analysis of the current data, and recommends an adjustment to the current
    /// temporary basal rate.
    func loop() {
        
        NSLog("myLoop: loop START")
        
        self.dataAccessQueue.async {
            NotificationCenter.default.post(name: .LoopRunning, object: self)

            self.lastLoopError = nil

            do {
                try self.update()

                if self.settings.dosingEnabled {
                    self.setRecommendedTempBasal { (error) -> Void in
                        self.lastLoopError = error

                        if let error = error {
                            self.logger.error(error)
                        } else {
                            self.lastLoopCompleted = Date()
                        }
                        self.notify(forChange: .tempBasal)
                    }

                    // Delay the notification until we know the result of the temp basal
                    return
                } else {
                    self.lastLoopCompleted = Date()
                }
            } catch let error {
                self.lastLoopError = error
            }

            self.notify(forChange: .tempBasal)
        }
    
        NSLog("myLoop: loop END")
    
    }

    // References to registered notification center observers
    private var carbUpdateObserver: Any?

    deinit {
        if let observer = carbUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld
    fileprivate func update() throws {

        NSLog("myLoop: update START")

        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        
        DispatchQueue.main.async{
            if( UIApplication.shared.applicationState == UIApplicationState.active ){
                NSLog("myLoop: ACTIVE")
            } else {
                NSLog("myLoop: BACKGROUND")
            }
        }
        
        let updateGroup = DispatchGroup()
        
        // Fetch glucose effects as far back as we want to make retroactive analysis
        var latestGlucoseDate: Date?
        updateGroup.enter()
        glucoseStore.getCachedGlucoseValues(start: Date(timeIntervalSinceNow: -recencyInterval)) { (values) in
            latestGlucoseDate = values.last?.startDate
            updateGroup.leave()
        }

        _ = updateGroup.wait(timeout: .distantFuture)
        
        guard let lastGlucoseDate = latestGlucoseDate else {
            throw LoopError.missingDataError(details: "Glucose data not available", recovery: "Check your CGM data source")
        }

        // Reinitialize integral retrospective correction states based on past 60 minutes of data
        // For now, do this only upon Loop relaunch
        if self.initializeIntegralRetrospectiveCorrection {
            self.initializeIntegralRetrospectiveCorrection = false
            let retrospectiveRestartDate = lastGlucoseDate.addingTimeInterval(TimeInterval(minutes: -60))
            
            // get insulin effects over the retrospective restart interval
            updateGroup.enter()
            doseStore.getGlucoseEffects(start: retrospectiveRestartDate.addingTimeInterval(TimeInterval(minutes: -60))) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.insulinEffect = nil
                case .success(let effects):
                    self.insulinEffect = effects
                }
                updateGroup.leave()
            }
            
            // get carb effects over the retrospective restart interval
            updateGroup.enter()
            carbStore.getGlucoseEffects(
                start: retrospectiveRestartDate.addingTimeInterval(TimeInterval(minutes: -60)),
                effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
            ) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.carbEffect = nil
                case .success(let effects):
                    self.carbEffect = effects
                }
                updateGroup.leave()
            }
            
            _ = updateGroup.wait(timeout: .distantFuture)
            
            
             let dateFormatter = DateFormatter()
             dateFormatter.dateStyle = .medium
             dateFormatter.timeStyle = .medium
             dateFormatter.locale = Locale(identifier: "en_US")
            
            var sampleGlucoseChangeEnd: Date = retrospectiveRestartDate
            while sampleGlucoseChangeEnd <= lastGlucoseDate {
                self.retrospectiveGlucoseChange = nil
                let sampleGlucoseChangeStart = sampleGlucoseChangeEnd.addingTimeInterval(TimeInterval(minutes: -30))
                updateGroup.enter()
                self.glucoseStore.getGlucoseChange(start: sampleGlucoseChangeStart, end: sampleGlucoseChangeEnd) { (change) in
                    self.retrospectiveGlucoseChange = change
                    updateGroup.leave()
                }
                
                _ = updateGroup.wait(timeout: .distantFuture)
                
                if let change = self.retrospectiveGlucoseChange {
                    let changeTimeInterval = change.end.endDate.timeIntervalSince(change.start.endDate).minutes
                    NSLog("myLoop: retrospection start: %@", dateFormatter.string(from: sampleGlucoseChangeStart))
                    NSLog("myLoop: retrospection end: %@", dateFormatter.string(from: sampleGlucoseChangeEnd))
                    NSLog("myLoop: retrospective minutes: %4.2f",changeTimeInterval)
                } else {
                    NSLog("myLoop: not able to determine glucose change")
                }
                
                self.glucoseUpdated = true
                do {
                    try updateRetrospectiveGlucoseEffect()
                } catch let error {
                    logger.error(error)
                }
                self.glucoseUpdated = false
                
                sampleGlucoseChangeEnd = sampleGlucoseChangeEnd.addingTimeInterval(TimeInterval(minutes: 5))
            }
            
            self.insulinEffect = nil
            self.carbEffect = nil
            self.retrospectiveGlucoseChange = nil
        }
        
        // original update() continues below
            
        let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-glucoseStore.reflectionDataInterval)

        if retrospectiveGlucoseChange == nil {
            updateGroup.enter()
            glucoseStore.getGlucoseChange(start: retrospectiveStart) { (change) in
                self.retrospectiveGlucoseChange = change
                updateGroup.leave()
            }
        }
        
        if lastGlucoseChange == nil {
            updateGroup.enter()
            let start = insulinCounteractionEffects.last?.endDate ?? lastGlucoseDate.addingTimeInterval(.minutes(-5.1))

            glucoseStore.getGlucoseChange(start: start) { (change) in
                self.lastGlucoseChange = change
                updateGroup.leave()
            }
        }
        
        if glucoseMomentumEffect == nil {
            updateGroup.enter()
            glucoseStore.getRecentMomentumEffect { (effects, error) -> Void in
                if let error = error, effects.count == 0 {
                    self.logger.error(error)
                    self.glucoseMomentumEffect = nil
                } else {
                    self.glucoseMomentumEffect = effects
                }

                updateGroup.leave()
            }
        }

        if insulinEffect == nil {
            updateGroup.enter()
            doseStore.getGlucoseEffects(start: retrospectiveStart) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.insulinEffect = nil
                case .success(let effects):
                    self.insulinEffect = effects
                }

                updateGroup.leave()
            }
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        if insulinCounteractionEffects.last == nil ||
            insulinCounteractionEffects.last!.endDate < lastGlucoseDate {
            do {
                try updateObservedInsulinCounteractionEffects()
            } catch let error {
                logger.error(error)
            }
        }
        
        if carbEffect == nil {
            updateGroup.enter()
            carbStore.getGlucoseEffects(
                start: retrospectiveStart,
                effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
            ) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.carbEffect = nil
                case .success(let effects):
                    self.carbEffect = effects
                }

                updateGroup.leave()
            }
        }

        if carbsOnBoard == nil {
            updateGroup.enter()
            carbStore.carbsOnBoard(at: Date(), effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil) { (result) in
                switch result {
                case .failure:
                    // Failure is expected when there is no carb data
                    self.carbsOnBoard = nil
                case .success(let value):
                    self.carbsOnBoard = value
                }
                updateGroup.leave()
            }
        }
        
        //let glucoseUnit = HKUnit.milligramsPerDeciliter() // do all calcs in mg/dL
        /*
        let estimationStart = lastGlucoseDate.addingTimeInterval(TimeInterval(hours: -estimationHours))
        // update past insulin and carb effects only if necessary and only if bg has just been updated
        if updatePastEffects {
            // update insulin effects over estimationHours
            if pastInsulinEffects == nil {
                updateGroup.enter()
                self.doseStore.getGlucoseEffects(start: estimationStart) { (result) -> Void in
                    switch result {
                    case .failure(let error):
                        self.logger.error(error)
                        NSLog("myLoop: *** could not get past insulin effects ***")
                    case .success(let effects):
                        self.pastInsulinEffects = effects
                        NSLog("myLoop: *** successfully updated array of insulin effects ***")
                    }
                    updateGroup.leave()
                }
            }
            
            // update carb effects over estimationHours
            if pastCarbEffects == nil {
                updateGroup.enter()
                self.carbStore.getGlucoseEffects(
                    start: estimationStart,
                    effectVelocities: self.settings.dynamicCarbAbsorptionEnabled ? self.insulinCounteractionEffects : nil
                ) { (result) -> Void in
                    switch result {
                    case .failure(let error):
                        self.logger.error(error)
                        NSLog("myLoop: *** could not get past carb effects ***")
                    case .success(let effects):
                        self.pastCarbEffects = effects
                        NSLog("myLoop: *** successfully updated array of carb effects ***")
                    }
                    updateGroup.leave()
                }
            }
        }
        updatePastEffects = false
        
        // initialize array of past 30-min glucose changes only when Loop is active, otherwise we cannot get past bg data
        DispatchQueue.main.async {
            if( self.pastGlucoseChanges == nil && UIApplication.shared.applicationState == UIApplicationState.active ){
                self.pastGlucoseChanges = []
                var sampleGlucoseChangeEnd: Date = estimationStart
                while sampleGlucoseChangeEnd <= lastGlucoseDate {
                    self.sampleRetrospectiveGlucoseChange = nil
                    //let glucoseUnit = HKUnit.milligramsPerDeciliter() // do all calcs in mg/dL
                    let sampleGlucoseChangeStart = sampleGlucoseChangeEnd.addingTimeInterval(TimeInterval(minutes: -30))
                    updateGroup.enter()
                    self.glucoseStore.getGlucoseChange(start: sampleGlucoseChangeStart, end: sampleGlucoseChangeEnd) { (change) in
                        self.sampleRetrospectiveGlucoseChange = change
                        updateGroup.leave()
                    }
                    
                    _ = updateGroup.wait(timeout: .distantFuture)
                    
                    if let change = self.sampleRetrospectiveGlucoseChange {
                        self.pastGlucoseChanges!.append(change)
                    }
                    sampleGlucoseChangeEnd = sampleGlucoseChangeEnd.addingTimeInterval(TimeInterval(minutes: 5))
                }
                if let countChanges = self.pastGlucoseChanges?.count {
                    if countChanges == 0 {
                        self.pastGlucoseChanges = nil
                    } else {
                        NSLog("myLoop: +++ inilialized %d past glucose changes +++", countChanges)
                    }
                } else {
                    NSLog("myLoop: XXX array of past BG changes not initialized XXX")
                }
            } else {
                if let countChanges = self.pastGlucoseChanges?.count {
                    NSLog("myLoop: *** array of past BG changes has %d elements ***", countChanges)
                } else {
                    NSLog("myLoop: XXX array of past BG changes not initialized yet XXX")
                }
            }
        }
        */
        
        _ = updateGroup.wait(timeout: .distantFuture)

        if retrospectivePredictedGlucose == nil {
            do {
                try updateRetrospectiveGlucoseEffect()
            } catch let error {
                logger.error(error)
            }
        }

        if predictedGlucose == nil {
            do {
                try updatePredictedGlucoseAndRecommendedBasalAndBolus()
            } catch let error {
                logger.error(error)

                throw error
            }
        }
        
        NSLog("myLoop: update END")
        
    }
    
    private func notify(forChange context: LoopUpdateContext) {
        var userInfo: [String: Any] = [
            type(of: self).LoopUpdateContextKey: context.rawValue
        ]

        if let lastLoopCompleted = lastLoopCompleted {
            userInfo[type(of: self).LastLoopCompletedKey] = lastLoopCompleted
        }

        NotificationCenter.default.post(name: .LoopDataUpdated,
            object: self,
            userInfo: userInfo
        )
    }

    /// Computes amount of insulin from boluses that have been issued and not confirmed, and
    /// remaining insulin delivery from temporary basal rate adjustments above scheduled rate
    /// that are still in progress.
    ///
    /// - Returns: The amount of pending insulin, in units
    /// - Throws: LoopError.configurationError
    private func getPendingInsulin() throws -> Double {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let basalRates = basalRateSchedule else {
            throw LoopError.configurationError("Basal Rate Schedule")
        }

        let pendingTempBasalInsulin: Double
        let date = Date()

        if let lastTempBasal = lastTempBasal, lastTempBasal.endDate > date {
            let normalBasalRate = basalRates.value(at: date)
            let remainingTime = lastTempBasal.endDate.timeIntervalSince(date)
            let remainingUnits = (lastTempBasal.unitsPerHour - normalBasalRate) * remainingTime.hours

            pendingTempBasalInsulin = max(0, remainingUnits)
        } else {
            pendingTempBasalInsulin = 0
        }

        let pendingBolusAmount: Double = lastRequestedBolus?.units ?? 0

        // All outstanding potential insulin delivery
        return pendingTempBasalInsulin + pendingBolusAmount
    }

    /// - Throws: LoopError.missingDataError
    fileprivate func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let model = insulinModelSettings?.model else {
            throw LoopError.configurationError("Check settings")
        }

        guard let glucose = self.glucoseStore.latestGlucose else {
            throw LoopError.missingDataError(details: "Cannot predict glucose due to missing input data", recovery: "Check your CGM data source")
        }

        var momentum: [GlucoseEffect] = []
        var effects: [[GlucoseEffect]] = []

        if inputs.contains(.carbs), let carbEffect = self.carbEffect {
            effects.append(carbEffect)
        }

        if inputs.contains(.insulin), let insulinEffect = self.insulinEffect {
            effects.append(insulinEffect)
        }

        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }

        if inputs.contains(.retrospection) {
            effects.append(self.retrospectiveGlucoseEffect)
        }

        var prediction = LoopMath.predictGlucose(glucose, momentum: momentum, effects: effects)

        // Dosing requires prediction entries at as long as the insulin model duration.
        // If our prediciton is shorter than that, then extend it here.
        let finalDate = glucose.startDate.addingTimeInterval(model.effectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }

        return prediction
    }

    // MARK: - Calculation state

    fileprivate let dataAccessQueue: DispatchQueue = DispatchQueue(label: "com.loudnate.Naterade.LoopDataManager.dataAccessQueue", qos: .default) // .utility, .default, .userInitiated, .userInteractive

    private var carbEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil

            // Carb data may be back-dated, so re-calculate the retrospective glucose.
            retrospectivePredictedGlucose = nil
        }
    }
    private var insulinEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
        }
    }
    private var glucoseMomentumEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
        }
    }
    private var retrospectiveGlucoseEffect: [GlucoseEffect] = [] {
        didSet {
            predictedGlucose = nil
        }
    }

    /// The change in glucose over the reflection time interval (default is 30 min)
    fileprivate var retrospectiveGlucoseChange: GlucoseChange? {
        didSet {
            retrospectivePredictedGlucose = nil
        }
    }
    /// The change in glucose over the last loop interval (5 min)
    fileprivate var lastGlucoseChange: GlucoseChange?

    fileprivate var predictedGlucose: [GlucoseValue]? {
        didSet {
            recommendedTempBasal = nil
            recommendedBolus = nil
        }
    }
    fileprivate var retrospectivePredictedGlucose: [GlucoseValue]? {
        didSet {
            retrospectiveGlucoseEffect = []
        }
    }
    fileprivate var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)?

    fileprivate var recommendedBolus: (recommendation: BolusRecommendation, date: Date)?
    
    fileprivate var carbsOnBoard: CarbValue?

    fileprivate var lastTempBasal: DoseEntry?
    fileprivate var lastRequestedBolus: (units: Double, date: Date)?
    fileprivate var lastLoopCompleted: Date? {
        didSet {
            NotificationManager.scheduleLoopNotRunningNotifications()

            AnalyticsManager.shared.loopDidSucceed()
        }
    }
    fileprivate var lastLoopError: Error? {
        didSet {
            if lastLoopError != nil {
                AnalyticsManager.shared.loopDidError()
            }
        }
    }
    
    /**
     Effects array for the parameter estimation filter
     **/
    class Effects {
        static var estimatorCounter: Int = 0
        var entries: [Double]
        var nonZeroCounter: Int = 0
        init() {
            entries = []
            nonZeroCounter = 0
        }
        func sum() -> Double {
            return(entries.reduce(0,+))
        }
        func weightedSum(weights: [Double]) -> Double {
            return(zip(entries, weights).map(*).reduce(0,+))
        }
        func incrementNonZeroCounter() -> Int {
            nonZeroCounter += 1
            return(nonZeroCounter)
        }
        func incrementCounter() -> Int {
            Effects.estimatorCounter += 1
            return(Effects.estimatorCounter)
        }
    }
    
    /**
     Calculate estimated parameter multipliers and confidence weights given effects at a single point
     **/
    private func determineMultipliersWeights(discrepancy: Double, insulin: Double, carbs: Double, basal: Double, parameterDeviation: Double) -> ((Double, Double, Double, Double, Double, Double, Double, Double)) {
        
        let keepThreshold = 0.50 // discard points with effect contribution less than keepThreshold
        let maxMultiplier = 1 + parameterDeviation // upper limit for the estimated multipliers
        let minMultiplier = 1 - parameterDeviation // lower limit for the estimated multipliers
        
        let basalMaxDiscrepancy: Double = abs(basal) * parameterDeviation // > 0
        let maximumExpectedDiscrepancy: Double = parameterDeviation *
            sqrt( pow(insulin, 2) + pow(carbs, 2) + pow(basal, 2) )
        
        var expectedDiscrepancyFraction: Double = 1.0
        var unexpectedPositiveFraction: Double = 0.0
        var unexpectedNegativeFraction: Double = 0.0
        
        // fraction of observed discrepancy that can be ascribed to variation in parameters
        if (discrepancy != 0.0) {
            expectedDiscrepancyFraction = min(maximumExpectedDiscrepancy / abs(discrepancy), 1.0)
            if (discrepancy > 0.0) {
                unexpectedPositiveFraction = 1.0 - expectedDiscrepancyFraction
            } else {
                unexpectedNegativeFraction = 1.0 - expectedDiscrepancyFraction
            }
        }
        
        // confidence weights are proportional to current effect magnitudes
        let weightBase = carbs + basalMaxDiscrepancy + abs(insulin)
        var insulinSensitivityWeight: Double = 0.0
        var carbSensitivityWeight: Double = 0.0
        var basalWeight: Double = 0.0
        if(weightBase > 0.0) {
            insulinSensitivityWeight = abs(insulin) / weightBase
            if(insulinSensitivityWeight < keepThreshold){
                insulinSensitivityWeight = 0.0
            }
            carbSensitivityWeight = carbs / weightBase
            if(carbSensitivityWeight < keepThreshold){
                carbSensitivityWeight = 0.0
            }
            basalWeight = basalMaxDiscrepancy / weightBase
            if(basalWeight < keepThreshold){
                basalWeight = 0.0
            }
        }
        
        // Allocate current observed discepancy to three parameters according to relative weights
        let insulinDiscrepancy = insulinSensitivityWeight * expectedDiscrepancyFraction * discrepancy
        let carbDiscrepancy = carbSensitivityWeight * expectedDiscrepancyFraction * discrepancy
        let basalDiscrepancy = basalWeight * expectedDiscrepancyFraction * discrepancy
        
        // Calculate parameter multipliers, observing limits
        var insulinSensitivityMultiplier: Double = 1.0
        if(insulin != 0){
            insulinSensitivityMultiplier = 1.0 + insulinDiscrepancy / insulin
            insulinSensitivityMultiplier =
                max( min(insulinSensitivityMultiplier, maxMultiplier), minMultiplier)
        }
        var carbSensitivityMultiplier: Double = 1.0
        if(carbs != 0){
            carbSensitivityMultiplier = 1.0 + carbDiscrepancy / carbs
            carbSensitivityMultiplier =
                max( min(carbSensitivityMultiplier, maxMultiplier), minMultiplier)
        }
        var basalMultiplier: Double = 1.0
        if(basal != 0) {
            basalMultiplier = 1.0 - basalDiscrepancy / basal
            basalMultiplier =
                max( min(basalMultiplier, maxMultiplier), minMultiplier)
        }
        return((insulinSensitivityMultiplier, insulinSensitivityWeight,
                carbSensitivityMultiplier, carbSensitivityWeight,
                basalMultiplier, basalWeight,
                unexpectedPositiveFraction, unexpectedNegativeFraction))
    }
    
    /**
     Get effects from stored effect array
    **/
    private func getEffects(retrospectiveEffects: [GlucoseEffectVelocity]) -> [Double]{
        let glucoseUnit = HKUnit.milligramsPerDeciliter() // do all calcs in mg/dL
        let velocityUnit = glucoseUnit.unitDivided(by: HKUnit.minute())
        var currentEffects: [Double] = []
        for effect in retrospectiveEffects {
            currentEffects.append(effect.quantity.doubleValue(for: velocityUnit))
        }
        return(currentEffects)
    }
    
    /**
     Parameter estimation math
     **/
    private func trackingParameterEstimator(currentDiscrepancy: Double, insulinEffect: Double, carbEffect: Double, endDate: Date) -> EstimatedParameters {

        var parameterEstimates = EstimatedParameters() // outputs of estimation filter
        
        // try to setup arrays based on health kit data WIP
        //let estimationInsulinEffects = pastInsulinEffects
        //let estimationCarbEffects = pastCarbEffects
        //let glucoseChanges = pastGlucoseChanges
        //let currentDate = estimationGlucoseValues.last!.startDate
        //let retrospectiveCurrentDate = currentDate.addingTimeInterval(TimeInterval(minutes: -30))
        /*
        NSLog("myLoop +++ past %d insulin effects found +++", estimationInsulinEffects.count)
        NSLog("myLoop +++ past %d carb effects found +++", estimationCarbEffects.count)
        NSLog("myLoop +++ past %d glucose changes found +++", glucoseChanges.count)
        */

        let glucoseUnit = HKUnit.milligramsPerDeciliter() // do all calcs in mg/dL
        let velocityUnit = glucoseUnit.unitDivided(by: HKUnit.minute())

        // Parameter estimation launched only if we were able to get user parameters
        // so it should be safe to unwrap sensitivities and basal rates here
        let insulinSensitivity = insulinSensitivitySchedule!
        let basalRates = basalRateSchedule!
        // Approximate basal impact based on the rate 2 hours ago
        let pastDate = endDate.addingTimeInterval(TimeInterval(minutes: -120))
        let pastBasalRate = basalRates.value(at: pastDate)
        //let glucoseUnit = HKUnit.milligramsPerDeciliter() // do all calcs in mg/dL
        let currentSensitivity = insulinSensitivity.quantity(at: endDate).doubleValue(for: glucoseUnit)
        // approximate 30-min BG impact of past basal rate
        let currentBasalEffect: Double = -pastBasalRate * currentSensitivity * 0.5 // < 0
        
        //var parameterEstimates = EstimatedParameters() // outputs of estimation filter
        let estimationHours = parameterEstimates.estimationHours
        let parameterDeviation = parameterEstimates.parameterDeviation
        let pointNoiseDeviation = parameterEstimates.pointNoiseDeviation
        
        let startDate = endDate.addingTimeInterval(TimeInterval(minutes: -30))
        
        let discrepancyQuantity = HKQuantity(unit: velocityUnit, doubleValue: currentDiscrepancy)
        let insulinQuantity = HKQuantity(unit: velocityUnit, doubleValue: insulinEffect)
        let carbQuantity = HKQuantity(unit: velocityUnit, doubleValue: carbEffect)
        let basalQuantity = HKQuantity(unit: velocityUnit, doubleValue: currentBasalEffect)
        
        // Insert and store new retrospective effects
        let discrepancyEffect = GlucoseEffectVelocity(startDate: startDate, endDate: endDate, quantity: discrepancyQuantity)
        retrospectiveDiscrepancies.insert(discrepancyEffect, at: 0)
        
        let insulinEffect = GlucoseEffectVelocity(startDate: startDate, endDate: endDate, quantity: insulinQuantity)
        retrospectiveInsulinEffects.insert(insulinEffect, at: 0)
        
        let carbEffect = GlucoseEffectVelocity(startDate: startDate, endDate: endDate, quantity: carbQuantity)
        retrospectiveCarbEffects.insert(carbEffect, at: 0)
        
        let basalEffect = GlucoseEffectVelocity(startDate: startDate, endDate: endDate, quantity: basalQuantity)
        retrospectiveBasalEffects.insert(basalEffect, at: 0)

        retrospectiveDiscrepancies = retrospectiveDiscrepancies.filterDateRange(Date(timeIntervalSinceNow: .hours(-estimationHours)), nil)
        retrospectiveInsulinEffects = retrospectiveInsulinEffects.filterDateRange(Date(timeIntervalSinceNow: .hours(-estimationHours)), nil)
        retrospectiveCarbEffects = retrospectiveCarbEffects.filterDateRange(Date(timeIntervalSinceNow: .hours(-estimationHours)), nil)
        retrospectiveBasalEffects = retrospectiveBasalEffects.filterDateRange(Date(timeIntervalSinceNow: .hours(-estimationHours)), nil)
        
        //let dateExample = retrospectiveBasalEffects[0].endDate
        //let hourExample = Calendar.current.component(.hour, from: dateExample)
        /*
        NSLog("my Loop: ^^^^ current hour = %d ^^^^",hourExample)
        let myEffects = retrospectiveBasalEffects.filter{ Calendar.current.component(.hour, from: $0.endDate) == 20 }
        NSLog("my Loop: ^^^^ found %d effects at hour = 20", myEffects.count)
        */
        
        // Estimation filter applies to arrays of effects data
        let currentInsulinEffects: [Double] = getEffects(retrospectiveEffects: retrospectiveInsulinEffects)
        let currentCarbEffects: [Double] = getEffects(retrospectiveEffects: retrospectiveCarbEffects)
        let currentBasalEffects: [Double] = getEffects(retrospectiveEffects: retrospectiveBasalEffects)
        let currentDiscrepancies: [Double] = getEffects(retrospectiveEffects: retrospectiveDiscrepancies)
        
        let estimatorEntries: Int = min(currentInsulinEffects.count, currentCarbEffects.count, currentBasalEffects.count, currentDiscrepancies.count)
        /*
        NSLog("myLoop Effect counts: %d, %d, %d, %d", currentInsulinEffects.count, currentCarbEffects.count, currentBasalEffects.count, currentDiscrepancies.count)
        */
        // Arrays of calculated multipliers and weights
        let insulinSensitivityMultipliers = Effects()
        let insulinSensitivityWeights = Effects()
        let carbSensitivityMultipliers = Effects()
        let carbSensitivityWeights = Effects()
        let basalMultipliers = Effects()
        let basalWeights = Effects()
        let unexpectedPositiveDiscrepancies = Effects()
        let unexpectedNegativeDiscrepancies = Effects()
        var insulinSensitivityPoints: Int = 0
        var carbSensitivityPoints: Int = 0
        var basalPoints: Int = 0
        
        for index in 0...(estimatorEntries - 1) {
            let (insulinSensitivityMultiplier, insulinSensitivityWeight,
             carbSensitivityMultiplier, carbSensitivityWeight,
             basalMultiplier, basalWeight,
             unexpectedPositiveFraction, unexpectedNegativeFraction) = determineMultipliersWeights(
                discrepancy: currentDiscrepancies[index],
                insulin: currentInsulinEffects[index],
                carbs: currentCarbEffects[index],
                basal: currentBasalEffects[index],
                parameterDeviation: parameterDeviation)
            /*
            NSLog("myLoop %d, ISF: %4.2f(%4.2f), CSF: %4.2f(%4.2f), B: %4.2f(%4.2f)", index, insulinSensitivityMultiplier, insulinSensitivityWeight, carbSensitivityMultiplier, carbSensitivityWeight, basalMultiplier, basalWeight)
            */
            if (insulinSensitivityWeight > 0) {
                insulinSensitivityPoints += 1
            }
            if (carbSensitivityWeight > 0) {
                carbSensitivityPoints += 1
            }
            if (basalWeight > 0) {
                basalPoints += 1
            }
            
            insulinSensitivityMultipliers.entries.insert(insulinSensitivityMultiplier, at: 0)
            insulinSensitivityWeights.entries.insert(insulinSensitivityWeight, at: 0)
            carbSensitivityMultipliers.entries.insert(carbSensitivityMultiplier, at: 0)
            carbSensitivityWeights.entries.insert(carbSensitivityWeight, at: 0)
            basalMultipliers.entries.insert(basalMultiplier, at: 0)
            basalWeights.entries.insert(basalWeight, at: 0)
            unexpectedPositiveDiscrepancies.entries.insert(100 * unexpectedPositiveFraction, at: 0)
            unexpectedNegativeDiscrepancies.entries.insert(100 * unexpectedNegativeFraction, at: 0)
        }
        /*
        NSLog("myLoop ISF points: %d, CSF points: %d, basal points: %d", insulinSensitivityPoints, carbSensitivityPoints, basalPoints)
        */
        // Multipliers and confidence levels found as weighted averages over estimation time
        var estimatedISFMultiplier: Double = 1.0
        var estimatedISFConfidence: Double = 0.0
        let insulinWeightsSum = insulinSensitivityWeights.sum()
        if(insulinWeightsSum != 0) {
            estimatedISFMultiplier = insulinSensitivityMultipliers.weightedSum(weights:insulinSensitivityWeights.entries) / insulinWeightsSum
            var insulinSensitivityDeviation: Double = 1.0
            if(insulinSensitivityPoints > 0) {
                insulinSensitivityDeviation = pointNoiseDeviation / sqrt(Double(insulinSensitivityPoints))
            }
            let insulinSensitivityUncertainty = 1.0 - insulinSensitivityWeights.weightedSum(weights:insulinSensitivityWeights.entries) / insulinWeightsSum
            estimatedISFConfidence = 100 * max(0, 1 - sqrt(pow(insulinSensitivityDeviation, 2) + pow(insulinSensitivityUncertainty, 2)))
        }
        
        var estimatedCSFMultiplier: Double = 1.0
        var estimatedCSFConfidence: Double = 0.0
        let carbWeightsSum = carbSensitivityWeights.sum()
        if(carbWeightsSum != 0) {
            estimatedCSFMultiplier = carbSensitivityMultipliers.weightedSum(weights: carbSensitivityWeights.entries) / carbWeightsSum
            var carbSensitivityDeviation: Double = 1.0
            if(carbSensitivityPoints > 0) {
                carbSensitivityDeviation = pointNoiseDeviation / sqrt(Double(carbSensitivityPoints))
            }
            let carbSensitivityUncertainty = 1.0 - carbSensitivityWeights.weightedSum(weights:carbSensitivityWeights.entries) / carbWeightsSum
            estimatedCSFConfidence = 100 * max(0, 1 - sqrt(pow(carbSensitivityDeviation, 2) + pow(carbSensitivityUncertainty, 2)))
        }
        
        var estimatedBasalMultiplier: Double = 1.0
        var estimatedBasalConfidence: Double = 0.0
        let basalWeightsSum = basalWeights.sum()
        if(basalWeightsSum != 0) {
            estimatedBasalMultiplier = basalMultipliers.weightedSum(weights: basalWeights.entries) / basalWeightsSum
            var basalDeviation: Double = 1.0
            if(basalPoints > 0) {
                basalDeviation = pointNoiseDeviation / sqrt(Double(basalPoints))
            }
            let basalUncertainty = 1.0 - basalWeights.weightedSum(weights:basalWeights.entries) / basalWeightsSum
            estimatedBasalConfidence = 100 * max(0, 1 - sqrt(pow(basalDeviation, 2) + pow(basalUncertainty, 2)))
        }
        
        // CR = ISF/CSF
        let estimatedCRMultiplier: Double = estimatedISFMultiplier / estimatedCSFMultiplier
        let estimatedCRConfidence: Double = max(0, 100 - sqrt(pow((100 - estimatedISFConfidence),2) +
            pow((100 - estimatedCSFConfidence),2)))
        
        // Unexpected discrepancies due to gross unmodeled factors, averages found over estimation time
        var unexpectedPositiveDiscrepancy: Double = 0.0
        var unexpectedNegativeDiscrepancy: Double = 0.0
        unexpectedPositiveDiscrepancy = unexpectedPositiveDiscrepancies.sum() / Double(unexpectedNegativeDiscrepancies.entries.count)
        unexpectedNegativeDiscrepancy = unexpectedNegativeDiscrepancies.sum() / Double(unexpectedNegativeDiscrepancies.entries.count)
        
        // How full is the estimation data buffer
        var estimationBufferPercentage: Double = Double(estimatorEntries) * 5 / (estimationHours * 60)
        estimationBufferPercentage = 100 * min(estimationBufferPercentage, 1.0)
        
        parameterEstimates.insulinSensitivityMultipler = estimatedISFMultiplier
        parameterEstimates.insulinSensitivityConfidence = estimatedISFConfidence.rounded()
        parameterEstimates.carbSensitivityMultiplier = estimatedCSFMultiplier
        parameterEstimates.carbSensitivityConfidence = estimatedCSFConfidence.rounded()
        parameterEstimates.basalMultiplier = estimatedBasalMultiplier
        parameterEstimates.basalConfidence = estimatedBasalConfidence.rounded()
        parameterEstimates.carbRatioMultiplier = estimatedCRMultiplier
        parameterEstimates.carbRatioConfidence = estimatedCRConfidence.rounded()
        parameterEstimates.unexpectedPositiveDiscrepancyPercentage = unexpectedPositiveDiscrepancy.rounded()
        parameterEstimates.unexpectedNegativeDiscrepancyPercentage = unexpectedNegativeDiscrepancy.rounded()
        parameterEstimates.estimationBufferPercentage = estimationBufferPercentage.rounded()
        
        return(parameterEstimates)
    }
    
    
    /**
     Update array of past effects used in parameter estimation
     */
    fileprivate func updateEffectsForEstimation() -> Void {
        // pastGlucoseChanges = array of past 30-min glucose changes over past estimationHours
        // pastInsulinEffects = insulin effects over past estimationHours
        // pastCarbEffects = carb effects over past estimationHours
        // pastEffects = array of start: Date, end: Date, deltaBG: Double, discrepancy: Double, insulinEffect: Double, carbEffect: Double, basalEffect: Double
        
        let glucoseUnit = HKUnit.milligramsPerDeciliter() // do all calcs in mg/dL
        // updateEffectsForEstimation launched only if we were able to get user parameters
        // so it should be safe to unwrap sensitivities and basal rates here
        let insulinSensitivity = insulinSensitivitySchedule!
        let basalRates = basalRateSchedule!
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        dateFormatter.locale = Locale(identifier: "en_US")
        
        if self.pastGlucoseChanges == nil || self.pastInsulinEffects == nil {
            self.pastEffects = nil // missing data, unable to update past Effects
            NSLog("myLoopS: XXX missing data, unable to update past effects XXX")
            return
        } else {
            //NSLog("myLoopS: **************** past effects **************************")
            self.pastEffects = []
            for glucoseChange in pastGlucoseChanges! {
                let startDate = glucoseChange.start.startDate
                let endDate = glucoseChange.end.startDate
                let deltaBG: Double = glucoseChange.end.quantity.doubleValue(for: glucoseUnit) - glucoseChange.start.quantity.doubleValue(for: glucoseUnit)
                
                // carb effect on bg
                var carbDeltaBG: Double = 0
                if pastCarbEffects != nil {
                    let carbGlucose = LoopMath.predictGlucose(glucoseChange.start, effects:
                        pastCarbEffects!.filterDateRange(startDate, endDate))
                    guard let lastCarbGlucose = carbGlucose.last else { continue }
                    carbDeltaBG = -glucoseChange.start.quantity.doubleValue(for: glucoseUnit) + lastCarbGlucose.quantity.doubleValue(for: glucoseUnit)
                }
                
                // insulin effect on bg
                let insulinGlucose = LoopMath.predictGlucose(glucoseChange.start, effects:
                    pastInsulinEffects!.filterDateRange(startDate, endDate))
                guard let lastInsulinGlucose = insulinGlucose.last else { continue }
                let insulinDeltaBG: Double = -glucoseChange.start.quantity.doubleValue(for: glucoseUnit) + lastInsulinGlucose.quantity.doubleValue(for: glucoseUnit)
                
                let discrepancy = deltaBG - ( carbDeltaBG + insulinDeltaBG )
                
                // approximate maximum basal effect based on the rate 2 hours ago
                let pastDate = startDate.addingTimeInterval(TimeInterval(minutes: -120))
                let pastBasalRate = basalRates.value(at: pastDate)
                //let glucoseUnit = HKUnit.milligramsPerDeciliter()
                let currentSensitivity = insulinSensitivity.quantity(at: startDate).doubleValue(for: glucoseUnit)
                // approximate 30-min BG impact of past basal rate
                let changeTimeInterval = glucoseChange.end.startDate.timeIntervalSince(glucoseChange.start.startDate).minutes
                let basalDeltaBG: Double = -pastBasalRate * currentSensitivity * changeTimeInterval / 60 // < 0
                
                let currentEffect: Effect = (startDate, endDate, deltaBG, discrepancy, insulinDeltaBG, carbDeltaBG, basalDeltaBG)
                _ = self.pastEffects!.append(currentEffect)
                
                //NSLog("myLoopS: %@: DeltaBG: %4.2f, I: %4.2f, B: %4.2f, C: %4.2f, D: %4.2f", dateFormatter.string(from: endDate), deltaBG, insulinDeltaBG, basalDeltaBG, carbDeltaBG, discrepancy)
            }
            if self.pastEffects!.count == 0 { self.pastEffects = nil }
        }
        return
    }
    
    /**
     Retrospective correction math, including proportional and integral action
     */
    fileprivate struct RetrospectiveCorrection {
        
        let discrepancyGain: Double
        let persistentDiscrepancyGain: Double
        let correctionTimeConstant: Double
        let integralGain: Double
        let integralForget: Double
        let proportionalGain: Double
        
        static var effectDuration: Double = 60
        static var previousDiscrepancy: Double = 0
        static var integralDiscrepancy: Double = 0
        
        init() {
            discrepancyGain = 1.0 // high-frequency RC gain, equivalent to Loop 1.5 gain = 1
            persistentDiscrepancyGain = 5.0 // low-frequency RC gain for persistent errors, must be >= discrepancyGain
            correctionTimeConstant = 90.0 // correction filter time constant in minutes
            let sampleTime: Double = 5.0 // sample time = 5 min
            integralForget = exp( -sampleTime / correctionTimeConstant ) // must be between 0 and 1
            integralGain = ((1 - integralForget) / integralForget) *
                (persistentDiscrepancyGain - discrepancyGain)
            proportionalGain = discrepancyGain - integralGain
        }
        func updateRetrospectiveCorrection(discrepancy: Double,
                                           positiveLimit: Double,
                                           negativeLimit: Double,
                                           carbEffect: Double,
                                           carbEffectLimit: Double,
                                           glucoseUpdated: Bool) -> Double {
            if (RetrospectiveCorrection.previousDiscrepancy * discrepancy < 0 ||
                (discrepancy > 0 && carbEffect > carbEffectLimit)){
                // reset integral action when discrepancy reverses polarity or
                // if discrepancy is positive and carb effect is greater than carbEffectLimit
                NSLog("myLoopRC: RESET %4.2f, %4.2f",RetrospectiveCorrection.previousDiscrepancy,discrepancy)
                RetrospectiveCorrection.effectDuration = 60.0
                RetrospectiveCorrection.previousDiscrepancy = 0.0
                RetrospectiveCorrection.integralDiscrepancy = integralGain * discrepancy
            } else {
                if (glucoseUpdated) {
                    NSLog("myLoopRC: UPDATE %4.2f, %4.2f",RetrospectiveCorrection.previousDiscrepancy,discrepancy)
                    // update integral action via low-pass filter y[n] = forget * y[n-1] + gain * u[n]
                    RetrospectiveCorrection.integralDiscrepancy =
                        integralForget * RetrospectiveCorrection.integralDiscrepancy +
                        integralGain * discrepancy
                    // impose safety limits on integral retrospective correction
                    RetrospectiveCorrection.integralDiscrepancy = min(max(RetrospectiveCorrection.integralDiscrepancy, negativeLimit), positiveLimit)
                    RetrospectiveCorrection.previousDiscrepancy = discrepancy
                    // extend duration of retrospective correction effect by 10 min, up to a maxium of 180 min
                    RetrospectiveCorrection.effectDuration =
                    min(RetrospectiveCorrection.effectDuration + 10, 180)
                }
            }
            let overallDiscrepancy = proportionalGain * discrepancy + RetrospectiveCorrection.integralDiscrepancy
            return(overallDiscrepancy)
        }
        func updateEffectDuration() -> Double {
            return(RetrospectiveCorrection.effectDuration)
        }
        func resetRetrospectiveCorrection() {
            RetrospectiveCorrection.effectDuration = 60.0
            RetrospectiveCorrection.previousDiscrepancy = 0.0
            RetrospectiveCorrection.integralDiscrepancy = 0.0
            return
        }
    }
    
    /**
     Runs the glucose retrospective analysis using the latest effect data.
     Updated to include integral retrospective correction.
 
     *This method should only be called from the `dataAccessQueue`*
     */
    private func updateRetrospectiveGlucoseEffect(effectDuration: TimeInterval = TimeInterval(minutes: 60)) throws {
        
        NSLog("myLoop: +++++++++++++++++++++++++++++++++++++++++++++++")
        NSLog("myLoop: rc START")
        
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        if glucoseUpdated {
            NSLog("myLoop: ooo updated RC glucose! ooo")
        } else {
            NSLog("myLoop: xxx RC for this glucose already done! xxx")
        }
        
        guard
            let carbEffect = self.carbEffect,
            let insulinEffect = self.insulinEffect
        else {
            self.retrospectivePredictedGlucose = nil
            throw LoopError.missingDataError(details: "Cannot retrospect glucose due to missing input data", recovery: nil)
        }
        
        // integral retrospective correction variables
        var dynamicEffectDuration: TimeInterval = effectDuration
        let retrospectiveCorrection = RetrospectiveCorrection()

        guard let change = retrospectiveGlucoseChange else {
            NSLog("myLoop --- suspected calibration event, no retrospective correction")
            self.overallRetrospectiveCorrection = nil
            self.glucoseUpdated = false
            self.retrospectivePredictedGlucose = nil
            return  // Expected case for calibrations
        }

        // Run a retrospective prediction over the duration of the recorded glucose change, using the current carb and insulin effects
        let startDate = change.start.startDate
        let endDate = change.end.endDate
        let retrospectivePrediction = LoopMath.predictGlucose(change.start, effects:
            carbEffect.filterDateRange(startDate, endDate),
            insulinEffect.filterDateRange(startDate, endDate)
        )

        guard let lastGlucose = retrospectivePrediction.last else {
            retrospectiveCorrection.resetRetrospectiveCorrection()
            self.overallRetrospectiveCorrection = nil
            self.glucoseUpdated = false
            self.retrospectivePredictedGlucose = nil
            NSLog("myLoop --- glucose data missing, reset retrospective correction")
            return
        }

        self.retrospectivePredictedGlucose = retrospectivePrediction
        
        let retrospectionTimeInterval = change.end.endDate.timeIntervalSince(change.start.endDate).minutes
        if retrospectionTimeInterval < 6 {
            self.overallRetrospectiveCorrection = nil
            self.glucoseUpdated = false
            self.retrospectivePredictedGlucose = nil
            NSLog("myLoop OOO too few glucose values, skip retrospective correction OOO")
            return
        }

        let glucoseUnit = HKUnit.milligramsPerDeciliter()
        let velocityUnit = glucoseUnit.unitDivided(by: HKUnit.second())

        // get user settings
        guard
            let glucoseTargetRange = settings.glucoseTargetRangeSchedule,
            let insulinSensitivity = insulinSensitivitySchedule,
            let basalRates = basalRateSchedule,
            let suspendThreshold = settings.suspendThreshold?.quantity,
            let carbRatio = carbRatioSchedule
            else {
                retrospectiveCorrection.resetRetrospectiveCorrection()
                self.overallRetrospectiveCorrection = nil
                self.glucoseUpdated = false
                self.retrospectivePredictedGlucose = nil
                NSLog("myLoop --- could not get settings, reset retrospective correction")
                return
        }
        let currentBG = change.end.quantity.doubleValue(for: glucoseUnit)
        let currentSensitivity = insulinSensitivity.quantity(at: endDate).doubleValue(for: glucoseUnit)
        let currentBasalRate = basalRates.value(at: endDate)
        let currentCarbRatio = carbRatio.value(at: endDate)
        let currentMinTarget = glucoseTargetRange.minQuantity(at: endDate).doubleValue(for: glucoseUnit)
        let currentSuspendThreshold = suspendThreshold.doubleValue(for: glucoseUnit)
        
        // safety limit for + integral action: ISF * (2 hours) * (basal rate)
        let integralActionPositiveLimit = currentSensitivity * 2 * currentBasalRate
        // safety limit for - integral action: suspend threshold - target
        let integralActionNegativeLimit = min(-15,-abs(currentMinTarget - currentSuspendThreshold))
        
        // safety limit for current discrepancy
        let discrepancyLimit = integralActionPositiveLimit
        let currentDiscrepancyUnlimited = change.end.quantity.doubleValue(for: glucoseUnit) - lastGlucose.quantity.doubleValue(for: glucoseUnit) // mg/dL
        let currentDiscrepancy = min(max(currentDiscrepancyUnlimited, -discrepancyLimit), discrepancyLimit)
        
        // retrospective carb effect
        let retrospectiveCarbEffect = LoopMath.predictGlucose(change.start, effects:
            carbEffect.filterDateRange(startDate, endDate))
        guard let lastCarbOnlyGlucose = retrospectiveCarbEffect.last else {
            retrospectiveCorrection.resetRetrospectiveCorrection()
            self.overallRetrospectiveCorrection = nil
            self.glucoseUpdated = false
            self.retrospectivePredictedGlucose = nil
            NSLog("myLoop --- could not get carb effect, skip retrospective correction")
            return
        }
        let currentCarbEffect = -change.start.quantity.doubleValue(for: glucoseUnit) + lastCarbOnlyGlucose.quantity.doubleValue(for: glucoseUnit)
        let scaledCarbEffect = currentCarbEffect * 30.0 / retrospectionTimeInterval
        
        // reset integral RC to standard RC if carbEffect over past 30 min is greater than carbEffectLimit expressed in mg/dL
        // calculate the limit based on CR and ISF settings
        let carbEffectLimit: Double = min( 200 * currentCarbRatio / currentSensitivity, 45 ) // [mg/dL] over 30 minutes
        // the above line may be replaced by a fixed value if so desired
        // let carbEffectLimit = 30 was used during ICR early testing, 15 was found by some to work better for kids

        // update overall retrospective correction
        let overallRC = retrospectiveCorrection.updateRetrospectiveCorrection(
            discrepancy: currentDiscrepancy,
            positiveLimit: integralActionPositiveLimit,
            negativeLimit: integralActionNegativeLimit,
            carbEffect: scaledCarbEffect,
            carbEffectLimit: carbEffectLimit,
            glucoseUpdated: glucoseUpdated
        )
        let effectMinutes = retrospectiveCorrection.updateEffectDuration()
       
        
        var scaledDiscrepancy = currentDiscrepancy
        if settings.integralRetrospectiveCorrectionEnabled {
            // retrospective correction including integral action
            scaledDiscrepancy = overallRC * 60.0 / effectMinutes // scaled to account for extended effect duration
            dynamicEffectDuration = TimeInterval(minutes: effectMinutes)
            // update retrospective correction display value
            overallRetrospectiveCorrection = HKQuantity(unit: glucoseUnit, doubleValue: overallRC)
        } else {
            // standard retrospective correction
            dynamicEffectDuration = effectDuration
            overallRetrospectiveCorrection = HKQuantity(unit: glucoseUnit, doubleValue: currentDiscrepancy)
        }
        
        // In Loop 1.5, velocity calculation had change.end.endDate.timeIntervalSince(change.0.endDate) in the denominator,
        // which could lead to too high RC gain when retrospection interval is short
        // IRC update: changed to a safe fixed default retrospection interval of 30*60 = 1800 seconds
        let velocity = HKQuantity(unit: velocityUnit, doubleValue: scaledDiscrepancy / 1800.0)
        let type = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier.bloodGlucose)!
        let glucose = HKQuantitySample(type: type, quantity: change.end.quantity, start: change.end.startDate, end: change.end.endDate)
        self.retrospectiveGlucoseEffect = LoopMath.decayEffect(from: glucose, atRate: velocity, for: dynamicEffectDuration)
        
        // retrospective insulin effect (just for monitoring RC operation)
        let retrospectiveInsulinEffect = LoopMath.predictGlucose(change.start, effects:
            insulinEffect.filterDateRange(startDate, endDate))
        guard let lastInsulinOnlyGlucose = retrospectiveInsulinEffect.last else {
            glucoseUpdated = false
            return
        }
        let currentInsulinEffect = -change.start.quantity.doubleValue(for: glucoseUnit) + lastInsulinOnlyGlucose.quantity.doubleValue(for: glucoseUnit)

        // retrospective average delta BG (just for monitoring RC operation)
        let currentDeltaBG = change.end.quantity.doubleValue(for: glucoseUnit) -
            change.start.quantity.doubleValue(for: glucoseUnit)// mg/dL

        // monitoring of retrospective correction in debugger or Console ("message: myLoop")
        
        NSLog("myLoop ******************************************")
        NSLog("myLoop ---retrospective correction ([mg/dL] bg unit)---")
        NSLog("myLoop Integral retrospective correction enabled: %d", settings.integralRetrospectiveCorrectionEnabled)
        NSLog("myLoop Current BG: %f", currentBG)
        NSLog("myLoop 30-min retrospective delta BG: %4.2f", currentDeltaBG)
        NSLog("myLoop Retrospective insulin effect: %4.2f", currentInsulinEffect)
        NSLog("myLoop Retrospectve carb effect: %4.2f", currentCarbEffect)
        NSLog("myLoop Carb effect limit: %4.2f", carbEffectLimit)
        NSLog("myLoop Current discrepancy: %4.2f", currentDiscrepancy)
        NSLog("myLoop Retrospective time interval: %4.2f", retrospectionTimeInterval)
        NSLog("myLoop Overall retrospective correction: %4.2f", overallRC)
        NSLog("myLoop Correction effect duration [min]: %4.2f", effectMinutes)

        // run parameter estimation only if glucose has been updated
        if (glucoseUpdated) {
            
            /*
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .medium
            dateFormatter.locale = Locale(identifier: "en_US")
            // if pastGlucoseChanges has been initialized,
            // append current 30-min change into pastGlucoseChanges array, trim array to estimation hours ***
            if (self.pastGlucoseChanges != nil && changeTimeInterval > 10) {
                _ = self.pastGlucoseChanges!.append(change)
                let estimationStart = endDate.addingTimeInterval(TimeInterval(hours: -estimationHours))
                self.pastGlucoseChanges = self.pastGlucoseChanges!.filter { $0.end.endDate >= estimationStart }
                let earliestDate = self.pastGlucoseChanges![0].end.endDate
                NSLog("myLoop: estimation start: %@", dateFormatter.string(from: estimationStart))
                NSLog("myLoop: earliest bg change: %@", dateFormatter.string(from: earliestDate))
                _ = updateEffectsForEstimation()
            } else {
                NSLog("myLoop: ??? nil array of glucose changes or too short change interval ???")
            }
             */
            
            /*
            // parameter estimation monitoring in debugger or Console ("message: myLoop")
            NSLog("myLoop ---parameter estimation------")
            
            self.estimatedParameters = trackingParameterEstimator(currentDiscrepancy: currentDiscrepancy, insulinEffect: currentInsulinEffect, carbEffect: currentCarbEffect, endDate: endDate)
            
            NSLog("myLoop Estimated ISF multiplier: %4.2f with %2.0f%% confidence", self.estimatedParameters.insulinSensitivityMultipler, self.estimatedParameters.insulinSensitivityConfidence)
            NSLog("myLoop Estimated CSF multiplier: %4.2f with %2.0f%% confidence", self.estimatedParameters.carbSensitivityMultiplier, self.estimatedParameters.carbSensitivityConfidence)
            NSLog("myLoop Estimated CR multiplier: %4.2f with %2.0f%% confidence", self.estimatedParameters.carbRatioMultiplier, self.estimatedParameters.carbRatioConfidence)
            NSLog("myLoop Estimated basal multiplier: %4.2f with %2.0f%% confidence", self.estimatedParameters.basalMultiplier, self.estimatedParameters.basalConfidence)
            NSLog("myLoop Unexpected +BG: %2.0f%%, unexpected -BG: %2.0f%%", self.estimatedParameters.unexpectedPositiveDiscrepancyPercentage, self.estimatedParameters.unexpectedNegativeDiscrepancyPercentage)
            */
        }
        
        glucoseUpdated = false // ensure that we only update integral RC once per bg update cycle
        NSLog("myLoop: rc END")
    }

    /// Measure the effects counteracting insulin observed in the CGM glucose.
    ///
    /// If you assume insulin is "right", this allows for some validation of carb algorithm settings.
    ///
    /// - Throws: LoopError.missingDataError if effect data isn't available
    private func updateObservedInsulinCounteractionEffects() throws {
        
        NSLog("myLoop: counteraction START")
        
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard
            let insulinEffect = self.insulinEffect
        else {
            throw LoopError.missingDataError(details: "Cannot calculate insulin counteraction due to missing input data", recovery: nil)
        }

        guard let change = lastGlucoseChange else {
            return  // Expected case for calibrations
        }

        // Predict glucose change using only insulin effects over the last loop interval
        let startDate = change.start.startDate
        let endDate = change.end.endDate.addingTimeInterval(TimeInterval(minutes: 5))
        let prediction = LoopMath.predictGlucose(change.start, effects:
            insulinEffect.filterDateRange(startDate, endDate)
        )

        // Ensure we're not repeating effects
        if let lastEffect = insulinCounteractionEffects.last {
            guard startDate >= lastEffect.endDate else {
                return
            }
        }

        // Compare that retrospective, insulin-driven prediction to the actual glucose change to
        // calculate the effect of all insulin counteraction
        guard let lastGlucose = prediction.last else { return }
        let glucoseUnit = HKUnit.milligramsPerDeciliter()
        let velocityUnit = glucoseUnit.unitDivided(by: HKUnit.second())
        let discrepancy = change.end.quantity.doubleValue(for: glucoseUnit) - lastGlucose.quantity.doubleValue(for: glucoseUnit) // mg/dL
        let averageVelocity = HKQuantity(unit: velocityUnit, doubleValue: discrepancy / change.end.endDate.timeIntervalSince(change.start.endDate))
        let effect = GlucoseEffectVelocity(startDate: startDate, endDate: change.end.startDate, quantity: averageVelocity)

        insulinCounteractionEffects.append(effect)
        // For now, only keep the last 24 hours of values
        insulinCounteractionEffects = insulinCounteractionEffects.filterDateRange(Date(timeIntervalSinceNow: .hours(-24)), nil)
    
        NSLog("myLoop: counteraction END")
    
    }

    /// Runs the glucose prediction on the latest effect data.
    ///
    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld

    private func updatePredictedGlucoseAndRecommendedBasalAndBolus() throws {

        NSLog("myLoop: prediction-recommendation START")
    
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let glucose = glucoseStore.latestGlucose else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(details: "Glucose", recovery: "Check your CGM data source")
        }

        guard let pumpStatusDate = doseStore.lastReservoirValue?.startDate else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(details: "Reservoir", recovery: "Check that your pump is in range")
        }

        let startDate = Date()

        guard startDate.timeIntervalSince(glucose.startDate) <= recencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard startDate.timeIntervalSince(pumpStatusDate) <= recencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }

        guard glucoseMomentumEffect != nil, carbEffect != nil, insulinEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(details: "Glucose effects", recovery: nil)
        }

        let predictedGlucose = try predictGlucose(using: settings.enabledEffects)
        self.predictedGlucose = predictedGlucose

        guard let
            maxBasal = settings.maximumBasalRatePerHour,
            let glucoseTargetRange = settings.glucoseTargetRangeSchedule,
            let insulinSensitivity = insulinSensitivitySchedule,
            let basalRates = basalRateSchedule,
            let maxBolus = settings.maximumBolus,
            let model = insulinModelSettings?.model
        else {
            throw LoopError.configurationError("Check settings")
        }
        
        guard lastRequestedBolus == nil
        else {
            // Don't recommend changes if a bolus was just requested.
            // Sending additional pump commands is not going to be
            // successful in any case.
            recommendedBolus = nil
            recommendedTempBasal = nil
            return
        }
        
        let tempBasal = predictedGlucose.recommendedTempBasal(
            to: glucoseTargetRange,
            suspendThreshold: settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            model: model,
            basalRates: basalRates,
            maxBasalRate: maxBasal,
            lastTempBasal: lastTempBasal
        )
        
        if let temp = tempBasal {
            recommendedTempBasal = (recommendation: temp, date: startDate)
        } else {
            recommendedTempBasal = nil
        }

        let pendingInsulin = try self.getPendingInsulin()
        
        let recommendation = predictedGlucose.recommendedBolus(
            to: glucoseTargetRange,
            suspendThreshold: settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            model: model,
            pendingInsulin: pendingInsulin,
            maxBolus: maxBolus
        )
        recommendedBolus = (recommendation: recommendation, date: startDate)
    }

    /// *This method should only be called from the `dataAccessQueue`*
    private func setRecommendedTempBasal(_ completion: @escaping (_ error: Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let recommendedTempBasal = self.recommendedTempBasal else {
            completion(nil)
            return
        }

        guard abs(recommendedTempBasal.date.timeIntervalSinceNow) < TimeInterval(minutes: 5) else {
            completion(LoopError.recommendationExpired(date: recommendedTempBasal.date))
            return
        }

        delegate.loopDataManager(self, didRecommendBasalChange: recommendedTempBasal) { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let basal):
                    self.lastTempBasal = basal
                    self.recommendedTempBasal = nil

                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            }
        }
    }
}


/// Describes a view into the loop state
protocol LoopState {
    /// The last-calculated carbs on board
    var carbsOnBoard: CarbValue? { get }

    /// An error in the current state of the loop, or one that happened during the last attempt to loop.
    var error: Error? { get }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    var insulinCounteractionEffects: [GlucoseEffectVelocity] { get }

    /// The last date at which a loop completed, from prediction to dose (if dosing is enabled)
    var lastLoopCompleted: Date? { get }

    /// The last set temp basal
    var lastTempBasal: DoseEntry? { get }

    /// The calculated timeline of predicted glucose values
    var predictedGlucose: [GlucoseValue]? { get }

    /// The recommended temp basal based on predicted glucose
    var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)? { get }

    var recommendedBolus: (recommendation: BolusRecommendation, date: Date)? { get }
    
    /// The retrospective prediction over a recent period of glucose samples
    var retrospectivePredictedGlucose: [GlucoseValue]? { get }

    /// Calculates a new prediction from the current data using the specified effect inputs
    ///
    /// This method is intended for visualization purposes only, not dosing calculation. No validation of input data is done.
    ///
    /// - Parameter inputs: The effect inputs to include
    /// - Returns: An timeline of predicted glucose values
    /// - Throws: LoopError.missingDataError if prediction cannot be computed
    func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue]
}


extension LoopDataManager {
    private struct LoopStateView: LoopState {
        private let loopDataManager: LoopDataManager
        private let updateError: Error?

        init(loopDataManager: LoopDataManager, updateError: Error?) {
            self.loopDataManager = loopDataManager
            self.updateError = updateError
        }

        var carbsOnBoard: CarbValue? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.carbsOnBoard
        }

        var error: Error? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return updateError ?? loopDataManager.lastLoopError
        }

        var insulinCounteractionEffects: [GlucoseEffectVelocity] {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.insulinCounteractionEffects
        }

        var lastLoopCompleted: Date? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.lastLoopCompleted
        }

        var lastTempBasal: DoseEntry? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.lastTempBasal
        }

        var predictedGlucose: [GlucoseValue]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.predictedGlucose
        }

        var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.recommendedTempBasal
        }
        
        var recommendedBolus: (recommendation: BolusRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.recommendedBolus
        }

        var retrospectivePredictedGlucose: [GlucoseValue]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.retrospectivePredictedGlucose
        }

        func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
            return try loopDataManager.predictGlucose(using: inputs)
        }
    }

    /// Executes a closure with access to the current state of the loop.
    ///
    /// This operation is performed asynchronously and the closure will be executed on an arbitrary background queue.
    ///
    /// - Parameter handler: A closure called when the state is ready
    /// - Parameter manager: The loop manager
    /// - Parameter state: The current state of the manager. This is invalid to access outside of the closure.
    func getLoopState(_ handler: @escaping (_ manager: LoopDataManager, _ state: LoopState) -> Void) {
        dataAccessQueue.async {
            var updateError: Error?

            do {
                try self.update()
            } catch let error {
                updateError = error
            }

            handler(self, LoopStateView(loopDataManager: self, updateError: updateError))
        }
    }
}


extension LoopDataManager {
    /// Generates a diagnostic report about the current state
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        getLoopState { (manager, state) in

            var entries = [
                "## LoopDataManager",
                "settings: \(String(reflecting: manager.settings))",
                "insulinCounteractionEffects: \(String(reflecting: manager.insulinCounteractionEffects))",
                "predictedGlucose: \(state.predictedGlucose ?? [])",
                "retrospectivePredictedGlucose: \(state.retrospectivePredictedGlucose ?? [])",
                "recommendedTempBasal: \(String(describing: state.recommendedTempBasal))",
                "recommendedBolus: \(String(describing: state.recommendedBolus))",
                "lastBolus: \(String(describing: manager.lastRequestedBolus))",
                "lastGlucoseChange: \(String(describing: manager.lastGlucoseChange))",
                "retrospectiveGlucoseChange: \(String(describing: manager.retrospectiveGlucoseChange))",
                "lastLoopCompleted: \(String(describing: state.lastLoopCompleted))",
                "lastTempBasal: \(String(describing: state.lastTempBasal))",
                "carbsOnBoard: \(String(describing: state.carbsOnBoard))"
            ]
            var loopError = state.error
            
            // TODO: this should be moved to doseStore.generateDiagnosticReport
            self.doseStore.insulinOnBoard(at: Date()) { (result) in

                let insulinOnBoard: InsulinValue?
                
                switch result {
                case .success(let value):
                    insulinOnBoard = value
                case .failure(let error):
                    insulinOnBoard = nil
                    
                    if loopError == nil {
                        loopError = error
                    }
                }
                
                entries.append("insulinOnBoard: \(String(describing: insulinOnBoard))")
                entries.append("error: \(String(describing: loopError))")
                entries.append("")

                self.glucoseStore.generateDiagnosticReport { (report) in
                    entries.append(report)
                    entries.append("")

                    self.carbStore.generateDiagnosticReport { (report) in
                        entries.append(report)
                        entries.append("")

                        self.doseStore.generateDiagnosticReport { (report) in
                            entries.append(report)
                            entries.append("")

                            completion(entries.joined(separator: "\n"))
                        }
                    }
                }
            }
        }
    }
}


extension Notification.Name {
    static let LoopDataUpdated = Notification.Name(rawValue:  "com.loudnate.Naterade.notification.LoopDataUpdated")

    static let LoopRunning = Notification.Name(rawValue: "com.loudnate.Naterade.notification.LoopRunning")
}


protocol LoopDataManagerDelegate: class {

    /// Informs the delegate that an immediate basal change is recommended
    ///
    /// - Parameters:
    ///   - manager: The manager
    ///   - basal: The new recommended basal
    ///   - completion: A closure called once on completion
    ///   - result: The enacted basal
    func loopDataManager(_ manager: LoopDataManager, didRecommendBasalChange basal: (recommendation: TempBasalRecommendation, date: Date), completion: @escaping (_ result: Result<DoseEntry>) -> Void) -> Void
}
