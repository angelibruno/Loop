//
//  StandardRetrospectiveCorrection.swift
//  Loop
//
//  Created by Dragan Maksimovic on 10/27/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit

/**
 Standard Retrospective Correction (RC) calculates a correction effect in glucose prediction based on the most recent discrepancy between observed glucose movement and movement expected based on insulin and carb models. Standard retrospective correction acts as a proportional (P) controller aimed at reducing modeling errors in glucose prediction.
 
 In the above summary, "discrepancy" is a difference between the actual glucose and the model predicted glucose over retrospective correction grouping interval (set to 30 min in LoopSettings)
 */
class StandardRetrospectiveCorrection: RetrospectiveCorrection {

    /// RetrospectiveCorrection protocol variables
    /// Standard effect duration
    let standardEffectDuration: TimeInterval
    /// Retrospective correction glucose effects
    var glucoseCorrectionEffect: [GlucoseEffect] = []

    /// All math is performed with glucose expressed in mg/dL
    private let unit = HKUnit.milligramsPerDeciliter
    /// Loop settings
    private let settings: LoopSettings
    
    /**
     Initialize standard retrospective correction based on user settings
     
     - Parameters:
        - settings: User settings
        - standardEffectDuration: Correction effect duration
     
     - Returns: Standard Retrospective Correction with user settings
     */
    init(_ settings: LoopSettings, _ standardEffectDuration: TimeInterval) {
        self.settings = settings
        self.standardEffectDuration = standardEffectDuration
    }
    
    /**
     Calculates overall correction effect based on the most recent discrepany, and updates glucoseCorrectionEffect
     
     - Parameters:
     - glucose: Most recent glucose
     - retrospectiveGlucoseDiscrepanciesSummed: Timeline of past discepancies
     
     - Returns:
     - totalRetrospectiveCorrection: Overall glucose effect
     */
    func updateRetrospectiveCorrectionEffect(_ glucose: GlucoseValue, _ retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?) -> HKQuantity? {
        
        // Last discrepancy should be recent, otherwise clear the effect and return
        let currentDate = Date()
        guard let currentDiscrepancy = retrospectiveGlucoseDiscrepanciesSummed?.last,
            currentDate.timeIntervalSince(currentDiscrepancy.endDate) <= settings.recencyInterval
            else {
                glucoseCorrectionEffect = []
                return( nil )
        }
        
        // Standard retrospective correction math
        let currentDiscrepancyValue = currentDiscrepancy.quantity.doubleValue(for: unit)
        let correction = HKQuantity(unit: unit, doubleValue: currentDiscrepancyValue)
        
        let retrospectionTimeInterval = currentDiscrepancy.endDate.timeIntervalSince(currentDiscrepancy.startDate)
        let discrepancyTime = max(retrospectionTimeInterval, settings.retrospectiveCorrectionGroupingInterval)
        let velocity = HKQuantity(unit: unit.unitDivided(by: .second()), doubleValue: currentDiscrepancyValue / discrepancyTime)
        
        // Update array of glucose correction effects
        glucoseCorrectionEffect = glucose.decayEffect(atRate: velocity, for: standardEffectDuration)
        
        // Return overall retrospective correction effect
        return(correction)
    }
}