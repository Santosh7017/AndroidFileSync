//
//  ThrottledPublisher.swift
//  AndroidFileSync
//
//  Created by Santosh Morya on 22/11/25.
//

//
//  ThrottledPublisher.swift
//  AndroidFileSync
//
//  Throttles rapid value updates to prevent UI lag
//

import Foundation
internal import Combine

extension Published.Publisher where Value: Equatable {
    /// Throttles updates to prevent UI lag
    func throttleUI(interval: TimeInterval = 0.5) -> Publishers.Throttle<Self, DispatchQueue> {
        throttle(for: .seconds(interval), scheduler: DispatchQueue.main, latest: true)
    }
}
